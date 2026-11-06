import copy
import hashlib
import json
from pathlib import Path
import sys
import unittest
import uuid
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import source_bound_map as extractive_maps
# Keep the previous generation/self-judge path's deterministic safety tests;
# production build_map below is V2 and has its own independent protocol tests.
maps = SimpleNamespace(**vars(extractive_maps))
maps.build_map = maps.build_map_v1
SPEAKER = str(uuid.uuid4())


def span(i, text="该方法只在条件稳定时有效。", origin=None):
    return {"id": str(uuid.uuid4()), "sequence": i, "startTime": i * 3,
            "endTime": i * 3 + 2, "originalText": text, "correctedText": None,
            "speakerID": SPEAKER, "origin": origin}


class Model:
    def __init__(self, verdict="supported", grouping=None, summaries=None):
        self.calls = []
        self.verdict, self.grouping = verdict, grouping
        self.summaries = summaries or ["该方法只在条件稳定时有效"]

    def __call__(self, llm, system, prompt, schema, **kwargs):
        self.calls.append((system, prompt, schema, kwargs))
        if "summaries" in schema["properties"]:
            return {"summaries": self.summaries}
        if "decisions" in schema["properties"]:
            count = schema["properties"]["decisions"]["minItems"]
            return {"decisions": [{"index": i, "reason": "stub only", "verdict": self.verdict} for i in range(count)]}
        keys = schema["properties"]["groups"]["items"]["properties"]["members"]["items"]["enum"]
        return self.grouping if self.grouping is not None else {"groups": [{"members": keys, "representative": keys[0]}]}


class SourceBoundMapV1Test(unittest.TestCase):
    def test_summary_and_citations_are_source_bound_and_input_unchanged(self):
        source = [span(0), span(1)]
        before = copy.deepcopy(source)
        model = Model()
        nodes, warnings = maps.build_map(None, source, model, "用户课程标题")
        self.assertEqual(source, before)
        self.assertEqual(warnings, [])
        self.assertEqual(len(model.calls), 2)
        self.assertTrue(nodes[0]["navigationRoot"])
        self.assertEqual(nodes[0]["summary"], "用户课程标题")
        self.assertTrue(nodes[0]["sourceSpanIDs"])
        self.assertEqual(nodes[1]["sourceSpanIDs"], [s["id"] for s in source])
        self.assertEqual(nodes[1]["argumentSummary"], "")
        self.assertNotIn("evidenceQuotes", model.calls[1][2]["properties"])

    def test_corrected_text_and_full_tail_are_in_generation_and_judgment(self):
        source = [span(0, "原识别说必定有效。"), span(1, "尾部指出不能用于另一种情况。")]
        source[0]["correctedText"] = "并不是必定有效。"
        model = Model()
        maps.build_map(None, source, model, "题目")
        for _, prompt, _, _ in model.calls:
            self.assertIn("并不是必定有效。", prompt)
            self.assertIn("尾部指出不能用于另一种情况。", prompt)
            self.assertNotIn("原识别说必定有效", prompt)

    def test_200_repetitions_remain_compact_and_cover_last_span(self):
        source = [span(i) for i in range(200)]
        source[-1]["originalText"] = "末段还有一条独立限制，不能忽略。"
        model = Model()
        nodes, warnings = maps.build_map(None, source, model, "长课")
        self.assertFalse(warnings)
        self.assertLessEqual(sum(n["kind"] != "证据" for n in nodes), 8)
        self.assertLess(len(nodes), 20)
        self.assertEqual(set(nodes[0]["coveredSourceSpanIDs"]), {s["id"] for s in source})
        self.assertEqual({i for n in nodes[1:] for i in n["coveredSourceSpanIDs"]}, {s["id"] for s in source})
        self.assertTrue(any("末段还有一条独立限制" in c[1] for c in model.calls if "decisions" in c[2]["properties"]))

    def test_unsupported_and_unknown_are_explicit_source_only_not_assertions(self):
        for verdict in ("contradicted", "unknown"):
            with self.assertRaisesRegex(ValueError, "尚未形成可靠概括"):
                maps.build_map(None, [span(0)], Model(verdict=verdict), "题目")

    def test_partial_unknown_keeps_original_and_warning_but_not_claim(self):
        model = Model(summaries=["该方法只在条件稳定时有效", "没有得到证据支持的观点"])
        def partial(llm, system, prompt, schema, **kwargs):
            result = model(llm, system, prompt, schema, **kwargs)
            if "decisions" in result:
                result["decisions"][1]["verdict"] = "unknown"
            return result
        nodes, warnings = maps.build_map(None, [span(0)], partial, "题目")
        self.assertTrue(warnings)
        self.assertTrue(any(n.get("sourceBoundStatus") == "sourceOnly" for n in nodes))
        self.assertFalse(any(n.get("summary") == "没有得到证据支持的观点" for n in nodes))

    def test_invalid_group_refs_never_enter_output(self):
        source = [span(i) for i in range(40)]
        for groups in ({"groups": [{"members": [0, 100], "representative": 0}]},
                       {"groups": [{"members": [0, 0], "representative": 0}]},
                       {"groups": [{"members": [0, 1], "representative": True}]}):
            with self.assertRaisesRegex(ValueError, "尚未形成可靠概括"):
                maps.build_map(None, source, Model(grouping=groups), "题目")

    def test_unseen_number_unit_rejected_despite_model_support(self):
        with self.assertRaisesRegex(ValueError, "尚未形成可靠概括"):
            maps.build_map(None, [span(0, "这里提到了160，但单位没有识别清楚。")],
                           Model(summaries=["讲者身高为160cm"]), "题目")

    def test_whole_quantity_tokens_not_substrings(self):
        for requested, source in (("等待2分钟", "等待12分钟"), ("高度60cm", "高度160cm"),
                                  ("等待２分钟", "等待１２分钟"), ("长度0.5米", "长度10.5米"),
                                  ("长度５．２厘米", "长度１５．２厘米"), ("等待十分钟", "等待二十分钟"),
                                  ("长度12厘米", "数字12没有单位"), ("增加2米", "增加-2米"),
                                  ("花费000元", "花费1,000元"), ("等待12分钟", "等待12多分钟")):
            with self.subTest(requested=requested, source=source):
                self.assertFalse(maps._numbers_supported(requested, source))
        for requested, source in (("等待１２分钟", "等待12分钟"), ("长度５．２厘米", "长度5.2厘米"),
                                  ("等待二十分钟", "明确等待二十分钟"), ("高度160cm", "高度160 cm"),
                                  ("数字12", "等待12分钟")):
            with self.subTest(requested=requested, source=source):
                self.assertTrue(maps._numbers_supported(requested, source))

    def test_incomplete_judge_does_not_publish_generated_words(self):
        model = Model()
        def incomplete(llm, system, prompt, schema, **kwargs):
            return {"decisions": []} if "decisions" in schema["properties"] else model(llm, system, prompt, schema, **kwargs)
        with self.assertRaisesRegex(ValueError, "尚未形成可靠概括"):
            maps.build_map(None, [span(0)], incomplete, "题目")

    def test_different_origin_courses_and_sequence_gaps_are_not_one_material(self):
        origin = lambda title: {"sessionID": str(uuid.uuid4()), "sessionTitle": title, "itemID": str(uuid.uuid4()), "startTime": 20}
        a, b = origin("原课A"), origin("原课B")
        source = [span(0, "甲课程原话。", a), span(1, "乙课程相反结论。", b), span(5, "断口后的限制。", b)]
        model = Model()
        maps.build_map(None, source, model, "综合")
        extracts = [c[1] for c in model.calls if "summaries" in c[2]["properties"]]
        self.assertEqual(len(extracts), 3)
        self.assertIn("原课A", extracts[0]); self.assertNotIn("原课B", extracts[0])
        self.assertIn("原课B", extracts[1])

    def test_oversized_complete_span_not_truncated_or_sent_to_model(self):
        source = [span(0, "完整原文" * 10_000 + "最后的否定。")]
        model = Model()
        with self.assertRaisesRegex(ValueError, "尚未形成可靠概括"):
            maps.build_map(None, source, model, "题目")
        self.assertEqual(model.calls, [])

    def test_invalid_source_fails_before_model(self):
        for invalid in ([span(0), span(0)], [dict(span(0), id="fake")], [dict(span(0), endTime=float("nan"))]):
            model = Model()
            with self.assertRaises(ValueError):
                maps.build_map(None, invalid, model, "题目")
            self.assertFalse(model.calls)


def extractive_only(*args, **kwargs):
    """Existing tests deliberately exercise extraction, not the product default."""
    return extractive_maps.build_map(*args, **kwargs, synthesize=False)


def planned(assignments, roles):
    return {"stageLabels": {key: role for key, role in roles.items()},
            "stageRoles": roles, "assignments": assignments}


class ExtractiveModel:
    def __init__(self):
        self.calls = []

    def __call__(self, llm, system, prompt, schema, **kwargs):
        self.calls.append((system, prompt, schema))
        records = json.loads(prompt.split("输入：", 1)[1])
        if "assignments" in schema["properties"]:
            keys = list(schema["properties"]["assignments"]["properties"])
            roles = {k: None for k in extractive_maps.STAGE_KEYS}
            if isinstance(records, dict):
                groups = records["groups"]
                distinct = list(dict.fromkeys(g["role"] for g in groups))
                assignments = {str(i): extractive_maps.STAGE_KEYS[distinct.index(g["role"])] for i, g in enumerate(groups)}
                for index, role in enumerate(distinct):
                    roles[extractive_maps.STAGE_KEYS[index]] = role
            else:
                assignments = {key: "A" for key in keys}
                roles["A"] = "执行动作"
            return planned(assignments, roles)
        return {stage: {"core": field["properties"]["core"]["items"]["enum"][:1],
                        "conditions": field["properties"]["core"]["items"]["enum"][1:2]}
                for stage, field in schema["properties"].items()}


class TokenBudget:
    def tokenize(self, value):
        return range((len(value) + 2) // 3)

    def n_ctx(self):
        return 8192


class SourceBoundMapV2Test(unittest.TestCase):
    def test_substantive_followup_step_can_be_explicit_supplement_not_just_context(self):
        source = [span(0, "先形成一个能够执行的方案。"), span(1, "完成后逐项核对结果，再处理尚未解决的问题。")]
        model = ExtractiveModel()
        def select(llm, system, prompt, schema, **kwargs):
            if "assignments" in schema["properties"]:
                return model(llm, system, prompt, schema, **kwargs)
            for duty in ("方法步骤", "关键理由", "验证办法", "后续行动", "适用条件和例外", "寒暄、重复"):
                self.assertIn(duty, prompt)
            self.assertIn("未进core的有意义论述", prompt)
            self.assertEqual(schema["properties"]["A"]["properties"]["conditions"]["maxItems"], 2)
            return {"A": {"core": [0], "conditions": [1]}}
        nodes, _ = extractive_only(None, source, select, "流程课程")
        self.assertEqual(nodes[1]["summary"], source[0]["originalText"])
        self.assertEqual([q["text"] for q in nodes[1]["conditionOriginals"]], [source[1]["originalText"]])
        self.assertIn(source[1]["id"], nodes[1]["sourceSpanIDs"])
        self.assertEqual(len(nodes), 2)  # supplement remains off the default map

    def test_same_complete_conditional_sentence_is_core_once_not_failure(self):
        sentence = "只有环境稳定时才使用这项方法，否则不能直接套用。"
        source = [span(0, sentence)]
        model = ExtractiveModel()
        def overlap(llm, system, prompt, schema, **kwargs):
            if "assignments" in schema["properties"]:
                return model(llm, system, prompt, schema, **kwargs)
            return {"A": {"core": [0], "conditions": [0]}}
        nodes, _ = extractive_only(None, source, overlap, "课名")
        self.assertEqual(nodes[1]["summary"], sentence)
        self.assertEqual([q["text"] for q in nodes[1]["coreOriginals"]], [sentence])
        self.assertEqual(nodes[1]["conditionOriginals"], [])
        self.assertEqual(nodes[1]["sourceSpanIDs"], [source[0]["id"]])
        self.assertEqual(source[0]["originalText"], sentence)

    def test_inherited_condition_promoted_to_core_is_not_repeated(self):
        source = [span(0, "一个方法。"), span(2, "只有满足限制才可使用。")]
        units = extractive_maps._make_units(source)
        groups = [{"members": [0, 1], "core": [0], "conditions": [1], "role": "执行动作"}]
        def overlap(llm, system, prompt, schema, **kwargs):
            if "assignments" in schema["properties"]:
                return planned({"0": "A"}, {k: "执行动作" if k == "A" else None for k in extractive_maps.STAGE_KEYS})
            return {"A": {"core": [1], "conditions": [1]}}
        merged = extractive_maps._merge_extractive(None, groups, units, overlap)
        self.assertEqual(merged[0]["core"], [1])
        self.assertEqual(merged[0]["conditions"], [])
        self.assertEqual(merged[0]["members"], [0, 1])
        self.assertEqual(units[1]["text"], source[1]["originalText"])

    def test_user_authorship_and_speaker_changes_do_not_join_teacher_source(self):
        course = {"sessionID": "course-a", "sessionTitle": "同一课"}
        source = [span(0, "老师原文", course), span(1, "用户想法", dict(course, authoredByUser=True)),
                  span(2, "另一位说话人", course)]
        source[2]["speakerID"] = str(uuid.uuid4())
        units = extractive_maps._make_units(source)
        self.assertEqual([u["text"] for u in units], ["老师原文", "用户想法", "另一位说话人"])
        self.assertTrue(units[1]["origin"]["authoredByUser"])
        self.assertNotEqual(units[0]["speakerKey"], units[2]["speakerKey"])
        with self.assertRaisesRegex(ValueError, "每个来源课程"):
            extractive_maps._require_course_cores([0, 1], [0], units)

    def test_real_sentence_units_not_hundreds_of_characters_aggregated(self):
        sentences = [f"第{i}个问题仍须结合实际条件再处理。" for i in range(40)]
        units = extractive_maps._make_units([span(0, "".join(sentences))])
        self.assertEqual([u["text"] for u in units], sentences)
        self.assertTrue(all(len(u["text"]) < 70 for u in units))

    def test_unpunctuated_fragments_short_passages_no_invented_words(self):
        source = [span(i, "这个连续片段没有句末标点") for i in range(100)]
        units = extractive_maps._make_units(source)
        self.assertEqual("".join(u["text"] for u in units), "".join(s["originalText"] for s in source))
        self.assertTrue(all(len(u["text"]) <= 150 for u in units))
        self.assertTrue(all(not u["completeSentenceBoundary"] for u in units))

    def test_long_real_sentence_condition_and_closing_quote_stay_complete(self):
        sentence = "他说：“" + "具体情况需要逐一核对，" * 25 + "但不能因此无条件使用。”"
        source = [span(0, sentence)]
        units = extractive_maps._make_units(source)
        self.assertEqual("".join(u["text"] for u in units), sentence)
        self.assertGreater(len(units), 1)
        self.assertTrue(all(len(u["text"]) <= 150 for u in units))
        self.assertTrue(units[-1]["text"].endswith("但不能因此无条件使用。”"))

    def test_sparse_final_full_stop_does_not_make_150_spans_one_giant_unit(self):
        source = [span(i, "这一段原文没有句末标点但是有完整来源") for i in range(150)]
        source[-1]["originalText"] += "。然后还有单独的后段。"
        units = extractive_maps._make_units(source)
        self.assertGreater(len(units), 15)
        self.assertTrue(all(len(u["text"]) <= 150 for u in units))
        self.assertEqual("".join(u["text"] for u in units), "".join(s["originalText"] for s in source))
        by_id = {s["id"]: s["originalText"] for s in source}
        for unit in units:
            self.assertEqual("".join(by_id[p["sourceID"]][p["startOffset"]:p["endOffset"]] for p in unit["parts"]), unit["text"])

    def test_long_single_span_uses_existing_clauses_and_preserves_whitespace(self):
        text = "\n  开头原文。\n\n" + "这一项需要逐步处理，" * 80 + "但须满足最后的限制。\n"
        source = [span(0, text)]
        units = extractive_maps._make_units(source)
        self.assertTrue(all(len(u["text"]) <= 150 for u in units))
        self.assertEqual("".join(u["text"] for u in units), text)
        self.assertTrue(any("但须满足最后的限制。" in u["text"] for u in units))
        for unit in units:
            self.assertEqual("".join(text[p["startOffset"]:p["endOffset"]] for p in unit["parts"]), unit["text"])

    def test_numeric_commas_and_clock_colons_are_not_clause_boundaries(self):
        text = "前置原文" * 30 + "1,000以及12:30" + "后置原文" * 20 + "。"
        units = extractive_maps._make_units([span(0, text)])
        self.assertEqual([u["text"] for u in units], [text])

    def test_two_courses_core_cannot_be_only_one_courses_statement(self):
        a = {"sessionID": "course-a", "sessionTitle": "甲"}
        b = {"sessionID": "course-b", "sessionTitle": "乙"}
        source = [span(0, "甲提出一种方法。", a), span(1, "乙指出条件不同。", b)]
        model = ExtractiveModel()  # chooses only the first course as core
        with self.assertRaises(ValueError):
            extractive_only(None, source, model, "综合")

    def test_exact_material_not_generated_summary_and_no_judge(self):
        source = [span(0, "第一部分说明条件，"), span(1, "仅满足条件时可以使用。")]
        original = copy.deepcopy(source)
        model = ExtractiveModel()
        nodes, warnings = extractive_only(None, source, model, "现有课名")
        self.assertEqual(source, original)
        self.assertEqual(nodes[1]["summary"], "第一部分说明条件，仅满足条件时可以使用。")
        self.assertEqual(nodes[1]["sourceBoundStatus"], "extracted")
        self.assertEqual(len(model.calls), 2)
        self.assertEqual(nodes[1]["navigationLabel"], "执行动作")
        self.assertIn("assignments", model.calls[0][2]["properties"])
        self.assertNotIn("verdict", model.calls[1][2]["properties"])
        self.assertTrue(warnings)

    def test_every_offset_reconstructs_actual_corrected_or_raw_text(self):
        source = [span(0, "不正确的识别"), span(1, "；后句有进一步的限制。")]
        source[0]["correctedText"] = "人工修正：并不无条件有效"
        by_id = {s["id"]: extractive_maps._text(s) for s in source}
        units = extractive_maps._make_units(source)
        self.assertEqual("".join(u["text"] for u in units), "".join(by_id[s["id"]] for s in source))
        for unit in units:
            self.assertEqual("".join(by_id[p["sourceID"]][p["startOffset"]:p["endOffset"]] for p in unit["parts"]), unit["text"])

    def test_438_fragments_merge_without_36_span_quota_and_keep_tail(self):
        source = [span(i, "连续的小段原文，") for i in range(438)]
        source[-1]["originalText"] = "最终还有不能忽略的限制"
        model = ExtractiveModel()
        nodes, _ = extractive_only(TokenBudget(), source, model, "长课")
        self.assertLessEqual(len(nodes), 8)
        self.assertLess(len(model.calls), 20)
        self.assertEqual({i for n in nodes for i in n["coveredSourceSpanIDs"]}, {s["id"] for s in source})
        self.assertTrue(any("最终还有不能忽略的限制" in c[1] for c in model.calls))

    def test_long_sentence_overbudget_fails_without_model_or_tail_truncation(self):
        text = "这是一份不能裁掉条件的完整长原话" * 3000 + "，但最后否定了该观点。"
        model = ExtractiveModel()
        with self.assertRaisesRegex(ValueError, "未截断"):
            extractive_only(None, [span(0, text)], model, "标题")
        self.assertFalse(model.calls)

    def test_origin_and_gap_never_join_and_global_sees_raw_context(self):
        a = {"sessionID": str(uuid.uuid4()), "sessionTitle": "甲课程", "startTime": 10}
        b = {"sessionID": str(uuid.uuid4()), "sessionTitle": "乙课程", "startTime": 30}
        source = [span(0, "甲认为满足条件才能执行。", a), span(1, "乙指出自己尚未实施。", b), span(5, "断口之后。", b)]
        units = extractive_maps._make_units(source)
        self.assertEqual(len(units), 3)
        self.assertEqual(extractive_maps._context_keys(1, units), [1])
        groups = [{"members": [0], "core": [0], "conditions": [], "role": "执行动作"},
                  {"members": [1, 2], "core": [1], "conditions": [2], "role": "适用条件"}]
        model = ExtractiveModel()
        merged = extractive_maps._merge_extractive(None, groups, units, model)
        self.assertEqual(len(merged), 2)
        self.assertIn("甲课程", model.calls[0][1]); self.assertIn("乙课程", model.calls[0][1])
        self.assertIn("尚未实施", model.calls[0][1])
        self.assertIn("断口之后", model.calls[0][1])

    def test_conditions_inherited_even_if_merge_does_not_repeat_keys(self):
        source = [span(0, "核心方法。"), span(2, "但只适用于本条件。"), span(4, "另一项方法。")]
        units = extractive_maps._make_units(source)
        groups = [{"members": [0, 1], "core": [0], "conditions": [1], "role": "执行动作"},
                  {"members": [2], "core": [2], "conditions": [], "role": "执行动作"}]
        def omit(llm, system, prompt, schema, **kwargs):
            if "assignments" in schema["properties"]:
                return planned({"0": "A", "1": "A"}, {k: "执行动作" if k == "A" else None for k in extractive_maps.STAGE_KEYS})
            return {"A": {"core": [0], "conditions": []}}
        result = extractive_maps._merge_extractive(None, groups, units, omit)
        self.assertEqual(result[0]["conditions"], [1])
        self.assertEqual(result[0]["members"], [0, 1, 2])

    def test_model_cannot_write_body_or_forge_missing_refs(self):
        source = [span(0, "真实原话。"), span(2, "第二条原话。")]
        for result in ({"groups": [{"members": [0, 1], "core": [999], "conditions": [], "role": "执行动作"}]},
                       {"groups": [{"members": [0, 0], "core": [0], "conditions": [], "role": "执行动作"}]},
                       {"groups": [{"members": [0, 1], "core": [True], "conditions": [], "role": "执行动作"}]},
                       {"groups": [{"members": [0, 1], "core": [0], "conditions": [], "role": "执行动作", "text": "伪造正文"}]}):
            with self.subTest(result=result):
                with self.assertRaises(ValueError):
                    extractive_only(None, source, lambda *args, **kwargs: result, "标题")

    def test_core_cannot_borrow_another_groups_source(self):
        source = [span(0, "甲原文。"), span(2, "乙原文。")]
        def bad(llm, system, prompt, schema, **kwargs):
            if "assignments" in schema["properties"]:
                return planned({"0": "A", "1": "B"}, {k: "执行动作" if k in "AB" else None for k in extractive_maps.STAGE_KEYS})
            return {"A": {"core": [1], "conditions": []}, "B": {"core": [0], "conditions": []}}
        with self.assertRaisesRegex(ValueError, "越界"):
            extractive_only(None, source, bad, "题目")

    def test_assignment_schema_owns_every_key_once_and_has_no_member_arrays(self):
        schema = extractive_maps._partition_schema(list(range(37)))
        fields = schema["properties"]["assignments"]
        self.assertEqual(len(fields["properties"]), 37)
        self.assertEqual(set(fields["required"]), {str(i) for i in range(37)})
        self.assertFalse(fields["additionalProperties"])
        self.assertNotIn("members", json.dumps(schema))
        self.assertTrue(extractive_maps._partition_reply_fits(TokenBudget(), list(range(37))))

    def test_choice_arrays_total_bound_tracks_partition_not_seven_times_input(self):
        allowed = {"A": list(range(10)), "B": list(range(10, 25)), "C": list(range(25, 37))}
        schema = extractive_maps._choice_schema(allowed)
        self.assertEqual(sum(v["properties"]["conditions"]["maxItems"] for v in schema["properties"].values()), 24)
        self.assertTrue(extractive_maps._choice_reply_fits(TokenBudget(), allowed))

    def test_missing_assignment_never_silently_drops_last_material(self):
        result = planned({"0": "A"}, {k: "执行动作" if k == "A" else None for k in extractive_maps.STAGE_KEYS})
        with self.assertRaisesRegex(ValueError, "遗漏"):
            extractive_maps._partition_result(result, [0, 1])

    def test_later_condition_can_attach_to_earlier_group_without_extra_global(self):
        source = [span(0, "前面提出了一项可尝试的方法。"), span(1, "中段讨论其他问题。"),
                  span(2, "补充：前面的方法只适用于满足条件的情况。")]
        calls = []
        def select(llm, system, prompt, schema, **kwargs):
            calls.append((prompt, schema))
            if "assignments" in schema["properties"]:
                return planned({"0": "A", "1": "B", "2": "B"}, {k: {"A": "执行动作", "B": "适用条件"}.get(k) for k in extractive_maps.STAGE_KEYS})
            self.assertEqual(schema["properties"]["A"]["properties"]["core"]["items"]["enum"], [0])
            self.assertIn(2, schema["properties"]["A"]["properties"]["conditions"]["items"]["enum"])
            return {"A": {"core": [0], "conditions": [2]}, "B": {"core": [1], "conditions": []}}
        nodes, _ = extractive_only(None, source, select, "课程")
        self.assertEqual(len(calls), 2)  # one page already has the full partition
        self.assertEqual(nodes[1]["conditionOriginals"][0]["text"], source[2]["originalText"])
        self.assertIn(source[2]["id"], nodes[1]["sourceSpanIDs"])
        self.assertEqual(nodes[1]["summary"], source[0]["originalText"])

    def test_cross_course_user_category_and_speaker_conditions_rejected(self):
        for change in (dict(origin={"sessionID": "other", "sessionTitle": "别课"}),
                       dict(origin={"sessionID": "local-session", "sessionTitle": "同课", "authoredByUser": True}),
                       dict(speakerID=str(uuid.uuid4()))):
            source = [span(0, "第一位讲者的方法。"), dict(span(1, "另一个来源的限制。"), **change)]
            def select(llm, system, prompt, schema, **kwargs):
                if "assignments" in schema["properties"]:
                    return planned({"0": "A", "1": "B"}, {k: "执行动作" if k in "AB" else None for k in extractive_maps.STAGE_KEYS})
                return {"A": {"core": [0], "conditions": [1]}, "B": {"core": [1], "conditions": []}}
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    extractive_only(None, source, select, "课程")

    def test_repeated_valid_core_reference_is_deduplicated_without_inference(self):
        source = [span(0, "采用低成本的行动方式。"), span(1, "执行后观察实际结果。")]
        units = [extractive_maps._unit_payload(u) for u in extractive_maps._make_units(source)]
        calls = []
        def select(*args, **kwargs):
            calls.append(1)
            return {"A": {"core": [0, 0], "conditions": [1]}}
        groups = extractive_maps._choose_cores(None, [{"stageKey": "A", "members": [0, 1], "role": "执行动作"}],
                                               {"A": [0, 1]}, units, select)
        self.assertEqual(groups[0]["core"], [0])
        self.assertEqual(groups[0]["conditions"], [1])
        self.assertEqual(calls, [1])

    def test_global_full_material_budget_failure_does_not_keep_only_selected_head(self):
        source = [span(i, "独立材料" * 50 + "。") for i in range(200)]
        units = extractive_maps._make_units(source)
        groups = [{"members": list(range(100)), "core": [0], "conditions": [], "role": "执行动作"},
                  {"members": list(range(100, 200)), "core": [100], "conditions": [], "role": "适用条件"}]
        model = ExtractiveModel()
        with self.assertRaisesRegex(ValueError, "未裁掉尾部"):
            extractive_maps._merge_extractive(TokenBudget(), groups, units, model)
        self.assertFalse(model.calls)

    def test_overbudget_global_merge_routes_labels_but_inherits_every_source_and_restriction(self):
        source = [span(i, f"完整原文{i}：" + "不能删除实际执行条件，" * 10 + "尾部也须保留。") for i in range(120)]
        units = extractive_maps._make_units(source)
        groups = [{"members": list(range(i, min(i + 10, len(units)))), "core": [i],
                   "conditions": [i + 1], "role": "执行动作", "label": f"方法{i // 10}"}
                  for i in range(0, len(units), 10)]
        before = copy.deepcopy((groups, units))
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            self.assertTrue(extractive_maps._fits(llm, system, prompt, schema, kwargs["max_tokens"]))
            data = json.loads(prompt.split("输入：", 1)[1])
            self.assertEqual(set(data), {"routingGroups", "sourceScopes"})
            self.assertEqual([r["groupKey"] for r in data["routingGroups"]], list(range(len(groups))))
            self.assertEqual([r["methodLabel"] for r in data["routingGroups"]], [g["label"] for g in groups])
            self.assertIn("不是原话或事实证据", prompt)
            self.assertIn("重新读取对应的真实原文", prompt)
            return planned({str(i): "ABC"[i % 3] for i in range(len(groups))},
                           {k: "执行动作" if k in "ABC" else None for k in extractive_maps.STAGE_KEYS})
        self.assertTrue(extractive_maps._merge_extractive(TokenBudget(), groups, units, complete, budget_only=True))
        self.assertFalse(calls)
        result = extractive_maps._merge_extractive(TokenBudget(), groups, units, complete)
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(result), 3)
        for field in ("members", "core", "conditions"):
            self.assertEqual(sorted(k for g in result for k in g[field]), sorted(k for g in groups for k in g[field]))
        self.assertEqual((groups, units), before)

    def test_routing_merge_rejects_missing_groups_and_retains_core_condition_overlap_once(self):
        units = extractive_maps._make_units([span(i) for i in range(4)])
        groups = [{"members": [0, 1], "core": [0], "conditions": [1, 2], "role": "执行动作", "label": "先验证"},
                  {"members": [2, 3], "core": [2], "conditions": [3], "role": "适用条件", "label": "再扩大"}]
        roles = {k: "执行动作" if k == "A" else None for k in extractive_maps.STAGE_KEYS}
        value = planned({"0": "A", "1": "A"}, roles)
        merged = extractive_maps._merge_routing_result(value, groups, units)
        self.assertEqual(merged[0]["members"], [0, 1, 2, 3])
        self.assertEqual(merged[0]["core"], [0, 2])
        self.assertEqual(merged[0]["conditions"], [1, 3])  # core 2 still carries its full literal condition
        with self.assertRaises(ValueError):
            extractive_maps._merge_routing_result(planned({"0": "A"}, roles), groups, units)


class NarrativeSynthesisTest(unittest.TestCase):
    def test_all_synthesis_adjacent_sources_are_in_candidate_archive(self):
        source = [span(i, f"材料{i}涉及具体处理的限制。") for i in range(5)]
        read_keys = []
        def complete(llm, system, prompt, schema, **kwargs):
            if "supported" in schema["properties"]:
                return {"supported": True, "issues": []}
            if "assignments" in schema["properties"]:
                return planned({"0": "A", "1": "B", "2": "A", "3": "B", "4": "B"},
                               {k: "执行动作" if k in "AB" else None for k in extractive_maps.STAGE_KEYS})
            if "summary" not in schema["properties"]:
                return {"A": {"core": [0], "conditions": []}, "B": {"core": [4], "conditions": []}}
            data = json.loads(prompt.split("输入：", 1)[1])
            read_keys.append([u["key"] for u in data["units"]])
            return {"navigationLabel": "处理条件", "summary": "处理时应结合各项材料中的限制。", "argumentSummary": "需要按照相关材料确认具体的处理条件与适用限制。"}
        nodes, _ = extractive_maps.build_map(None, source, complete, "课程")
        self.assertIn(3, read_keys[0])  # neighbor of unselected member 2, not core 0
        for node, keys in zip(nodes[1:], read_keys):
            self.assertEqual(set(node["sourceSpanIDs"]), {source[k]["id"] for k in keys})
            self.assertEqual(node["sourceSpanIDs"], node["coveredSourceSpanIDs"])

    def test_plan_precedes_assignment_and_empty_planned_slot_is_ignored(self):
        schema = extractive_maps._partition_schema([0, 1])
        self.assertEqual(list(schema["properties"]), ["stageLabels", "stageRoles", "assignments"])
        result = planned({"0": "A", "1": "A"}, {k: "执行动作" if k in "AB" else None for k in extractive_maps.STAGE_KEYS})
        parsed = extractive_maps._partition_result(result, [0, 1])
        self.assertEqual([g["stageKey"] for g in parsed], ["A"])
        self.assertEqual(parsed[0]["members"], [0, 1])
        result["stageRoles"]["B"] = result["stageLabels"]["B"] = None
        self.assertEqual(len(extractive_maps._partition_result(result, [0, 1])), 1)

    def test_used_stage_still_requires_label_and_role(self):
        for field in ("stageLabels", "stageRoles"):
            result = planned({"0": "A", "1": "B"}, {k: "执行动作" if k in "ABC" else None for k in extractive_maps.STAGE_KEYS})
            result[field]["B"] = None
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, "已用阶段缺少"):
                    extractive_maps._partition_result(result, [0, 1])

    def test_multiple_used_stages_ignore_only_empty_slot_without_reassigning(self):
        assignments = {str(k): extractive_maps.STAGE_KEYS[k % 6] for k in range(38)}
        result = planned(assignments, {k: "执行动作" for k in extractive_maps.STAGE_KEYS})
        parsed = extractive_maps._partition_result(result, list(range(38)))
        self.assertEqual(len(parsed), 6)
        self.assertEqual(sorted(k for g in parsed for k in g["members"]), list(range(38)))
        self.assertTrue(all(assignments[str(k)] == g["stageKey"] for g in parsed for k in g["members"]))
        self.assertEqual(result["assignments"], assignments)

    def test_invalid_navigation_label_is_not_silently_clipped(self):
        result = planned({"0": "A"}, {k: "执行动作" if k == "A" else None for k in extractive_maps.STAGE_KEYS})
        for label in ("", " ", "过长" * 11, False):
            result["stageLabels"]["A"] = label
            with self.assertRaisesRegex(ValueError, "标签"):
                extractive_maps._partition_result(result, [0])

    def test_product_default_synthesizes_all_members_not_only_core_or_supplements(self):
        source = [span(i, f"材料{i}需要按实际情况处理。") for i in range(12)]
        source[-1]["correctedText"] = "后续还须验证结果，条件不成立时不能继续。"
        original = copy.deepcopy(source)
        model = ExtractiveModel()
        synthesis_calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            if "supported" in schema["properties"]:
                return {"supported": True, "issues": []}
            if "summary" not in schema["properties"]:
                return model(llm, system, prompt, schema, **kwargs)
            data = json.loads(prompt.split("输入：", 1)[1])
            synthesis_calls.append(data)
            self.assertEqual(data["memberKeys"], list(range(12)))
            self.assertEqual([u["text"] for u in data["units"]], [extractive_maps._text(s) for s in source])
            self.assertIn("不成立时不能继续", data["units"][-1]["text"])
            self.assertEqual(data["attachedSupplementKeys"], [1])
            self.assertEqual(kwargs["max_tokens"], 1000)
            self.assertNotIn("verdict", schema["properties"])
            return {"navigationLabel": "处理条件", "summary": "依据实际情况推进处理，并保留验证与停止条件。",
                    "argumentSummary": "处理时需要结合各项材料；后续验证结果，条件不成立时不能继续。"}
        nodes, warnings = extractive_maps.build_map(TokenBudget(), source, complete, "课程", expand_branches=False)
        self.assertEqual(len(synthesis_calls), 1)
        self.assertEqual(len(model.calls), 2)
        self.assertEqual(nodes[1]["sourceBoundStatus"], "summarized")
        self.assertEqual(nodes[1]["semanticRole"], "assertion")
        self.assertNotEqual(nodes[1]["summary"], source[0]["originalText"])
        self.assertEqual(nodes[1]["coreOriginals"][0]["text"], source[0]["originalText"])
        self.assertEqual(source, original)
        self.assertEqual(set(nodes[1]["coveredSourceSpanIDs"]), {s["id"] for s in source})
        self.assertTrue(any("AI概括" in w for w in warnings))

    def test_synthesis_preserves_origin_authorship_and_attached_cross_stage_condition(self):
        a = {"sessionID": "a", "sessionTitle": "甲课程"}
        b = {"sessionID": "b", "sessionTitle": "我的记录", "authoredByUser": True}
        source = [span(0, "甲认为需要按条件处理。", a), span(1, "我对此仍有疑问。", b),
                  span(2, "甲在后段补充只在稳定环境适用。", a)]
        units = extractive_maps._make_units(source)
        group = {"members": [0, 1], "conditions": [2], "core": [0, 1], "role": "适用条件"}
        def complete(llm, system, prompt, schema, **kwargs):
            if "supported" in schema["properties"]:
                return {"supported": True, "issues": []}
            data = json.loads(prompt.split("输入：", 1)[1])
            self.assertEqual(data["memberKeys"], [0, 1])
            self.assertEqual(data["attachedSupplementKeys"], [2])
            self.assertEqual([u["origin"] for u in data["units"]], [a, b, a])
            self.assertIn("不能把甲的理由移给乙", prompt)
            return {"navigationLabel": "处理条件", "summary": "甲的方法存在适用前提，用户另有疑问。", "argumentSummary": "甲补充稳定环境这一限制；用户的疑问作为独立看法保留。"}
        extractive_maps._synthesize_stage(None, group, units, complete)

    def test_synthesis_rejects_bad_empty_overlong_or_truncated_result(self):
        units = extractive_maps._make_units([span(0, "一项需要结合条件的方案。")])
        group = {"members": [0], "core": [0], "conditions": [], "role": "执行动作"}
        valid = {"navigationLabel": "处理条件", "summary": "这是一项需要结合条件的方案。", "argumentSummary": "使用前需要确认条件是否成立。"}
        invalid = [None, '{"summary":"被截断', {"navigationLabel": "处理条件", "summary": valid["summary"]},
                   dict(valid, summary=" "), dict(valid, summary="长" * 101),
                   dict(valid, argumentSummary="长" * 601), dict(valid, extra=True)]
        for value in invalid:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    extractive_maps._synthesize_stage(None, group, units, lambda *a, **kw: value)

    def test_complete_stage_overbudget_delegates_all_evidence_without_tail_truncation(self):
        from unittest.mock import patch
        source = [span(i, "完整内容" * 100 + "。") for i in range(100)]
        units = extractive_maps._make_units(source)
        group = {"members": list(range(len(units))), "core": [0], "conditions": [], "role": "执行动作"}
        calls = []
        completion = lambda *a, **kw: calls.append(a)
        llm = TokenBudget()
        with patch("stage_synthesis.synthesize_overflow_stage", return_value={"summary": "bounded helper result"}) as helper:
            result = extractive_maps._synthesize_stage(llm, group, units, completion)
            helper.assert_called_once_with(llm, group, units, completion, previous=None, issues=None)
            self.assertEqual(result, {"summary": "bounded helper result"})
        self.assertEqual(calls, [])

    def test_later_synthesis_failure_returns_no_partial_map(self):
        source = [span(0, "先分析现状与已有依据。"), span(2, "再结合限制尝试新的方法。")]
        synthesized = []
        def complete(llm, system, prompt, schema, **kwargs):
            if "supported" in schema["properties"]:
                return {"supported": True, "issues": []}
            if "assignments" in schema["properties"]:
                return planned({"0": "A", "1": "B"}, {k: "执行动作" if k in "AB" else None for k in extractive_maps.STAGE_KEYS})
            if "summary" not in schema["properties"]:
                return {"A": {"core": [0], "conditions": []}, "B": {"core": [1], "conditions": []}}
            synthesized.append(prompt)
            if len(synthesized) == 2:
                raise ValueError("截断的模型回复")
            return {"navigationLabel": "处理条件", "summary": "先分析已有依据和现状。", "argumentSummary": "依据当前材料，先确认已知情况。"}
        original = copy.deepcopy(source)
        with self.assertRaisesRegex(ValueError, "截断"):
            extractive_maps.build_map(None, source, complete, "课程")
        self.assertEqual(len(synthesized), 2)
        self.assertEqual(source, original)

    def test_large_single_theme_is_not_forced_into_three_but_warns(self):
        source = [span(i, "同一项方法需要逐一确认实际条件。") for i in range(15)]
        nodes, warnings = extractive_only(TokenBudget(), source, ExtractiveModel(), "单一主题")
        self.assertEqual(len(nodes), 2)
        self.assertTrue(any("高度集中" in w for w in warnings))


class BoundedSourceReviewTest(unittest.TestCase):
    def test_wrong_planning_title_is_replaced_by_single_generated_title(self):
        source = [span(0, "这项安排只在环境稳定时试行，不能视为无条件适用。")]
        model = ExtractiveModel()
        calls = []
        drafts = [{"navigationLabel": "无条件适用", "summary": "这项安排在稳定环境下试行。", "argumentSummary": "需要保留环境稳定的前提，并且不能理解为无条件适用。"},
                  {"navigationLabel": "稳定环境下试行", "summary": "这项安排在稳定环境下试行。", "argumentSummary": "需要保留环境稳定的前提，并且不能理解为无条件适用。"}]
        def complete(llm, system, prompt, schema, **kwargs):
            if "assignments" in schema["properties"]:
                result = model(llm, system, prompt, schema, **kwargs)
                result["stageLabels"]["A"] = "无条件适用"
                return result
            if "summary" not in schema["properties"] and "supported" not in schema["properties"]:
                return model(llm, system, prompt, schema, **kwargs)
            payload = json.loads(prompt.split("输入：", 1)[1])
            calls.append(payload)
            self.assertEqual(payload["units"][0]["text"], source[0]["originalText"])
            if "supported" in schema["properties"]:
                self.assertIn("navigationLabel标题", prompt)
                if len(calls) == 2:
                    self.assertEqual(payload["draft"]["navigationLabel"], "无条件适用")
                    return {"supported": False, "issues": ["标题写无条件适用，但原文明确限制环境稳定且只在试行。"]}
                self.assertEqual(payload["draft"]["navigationLabel"], "稳定环境下试行")
                return {"supported": True, "issues": []}
            if len(calls) == 3:
                self.assertEqual(payload["previousDraft"]["navigationLabel"], "无条件适用")
            return drafts[1]
        nodes, _ = extractive_maps.build_map(None, source, complete, "课程")
        self.assertEqual(len(calls), 1)
        self.assertEqual(nodes[1]["navigationLabel"], "稳定环境下试行")
        self.assertEqual(nodes[1]["coreOriginals"][0]["text"], source[0]["originalText"])

    def test_title_only_unsupported_still_rejects_after_one_edit(self):
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(schema)
            if "supported" in schema["properties"]:
                return {"supported": False, "issues": ["仅标题将可能帮助改为必然保证，正文虽保留限定仍不足以纠正标题。"]}
            return dict(self.corrected, navigationLabel="必然保证有效")
        with self.assertRaisesRegex(ValueError, "仍未通过.*标题"):
            extractive_maps._checked_synthesis(None, self.group, self.units, complete)
        self.assertEqual(len(calls), 4)

    def test_missing_blank_overlong_title_rejects_before_review(self):
        for title in (None, "", "  ", "长" * 25, False):
            draft = dict(self.corrected, navigationLabel=title)
            if title is None:
                del draft["navigationLabel"]
            calls = []
            def complete(*args, **kwargs):
                calls.append(args)
                return draft
            with self.subTest(title=title):
                with self.assertRaises(ValueError):
                    extractive_maps._checked_synthesis(None, self.group, self.units, complete)
                self.assertEqual(len(calls), 1)

    def setUp(self):
        origin = {"sessionID": "source-course", "sessionTitle": "材料课程", "authoredByUser": True}
        self.source = [span(0, "这项安排可能帮助减少等待。", origin), span(1, "后续要核对是否满足条件。", origin),
                       span(2, "在特殊环境下仍需另行判断，不保证效果。", origin)]
        self.source[1]["correctedText"] = "人工修正：后续仍需确认两项条件同时成立。"
        self.units = extractive_maps._make_units(self.source)
        self.group = {"members": [0, 1], "core": [0], "conditions": [2], "role": "执行动作"}
        self.draft = {"navigationLabel": "处理条件", "summary": "这项安排能够保证减少等待。", "argumentSummary": "使用这一安排就能避免等待，其他情况不必再确认。"}
        self.corrected = {"navigationLabel": "处理条件", "summary": "安排可能减少等待，仍须确认适用条件。", "argumentSummary": "后续核对两项条件是否同时成立；特殊环境需另行判断，效果没有保证。"}
        self.issue = "草稿将可能帮助改为保证，并漏掉两项条件同时成立及特殊环境下需另行判断的限定。"

    def test_single_correction_four_calls_same_complete_sources_and_literal_quotes(self):
        calls = []
        responses = [self.draft, {"supported": False, "issues": [self.issue]}, self.corrected, {"supported": True, "issues": []}]
        def complete(llm, system, prompt, schema, **kwargs):
            payload = json.loads(prompt.split("输入：", 1)[1])
            calls.append((system, payload, schema))
            return responses[len(calls) - 1]
        before = copy.deepcopy(self.source)
        result = extractive_maps._checked_synthesis(TokenBudget(), self.group, self.units, complete)
        self.assertEqual(result, self.corrected)
        self.assertEqual(len(calls), 4)
        for _, payload, _ in calls:
            self.assertEqual(payload["units"], extractive_maps._stage_payload(self.group, self.units)["units"])
            self.assertEqual(payload["attachedSupplementKeys"], [2])
            self.assertTrue(all(u["origin"]["authoredByUser"] for u in payload["units"]))
            self.assertIn("两项条件同时成立", payload["units"][1]["text"])
        self.assertEqual(calls[2][1]["previousDraft"], self.draft)
        self.assertEqual(calls[2][1]["editingIssues"], [self.issue])
        self.assertEqual(calls[3][1]["draft"], self.corrected)
        self.assertNotEqual(calls[0][0], calls[1][0])
        self.assertEqual(self.source, before)

    def test_supported_first_draft_needs_only_two_calls_no_word_blacklist(self):
        # Even a phrase containing a guarantee is not rejected lexically.
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(schema)
            return {"supported": True, "issues": []} if "supported" in schema["properties"] else self.draft
        result = extractive_maps._checked_synthesis(None, self.group, self.units, complete)
        self.assertEqual(result, self.draft)
        self.assertEqual(len(calls), 2)

    def test_second_false_stops_at_four_calls_and_reports_issues(self):
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(schema)
            return {"supported": False, "issues": [self.issue]} if "supported" in schema["properties"] else self.draft
        with self.assertRaisesRegex(ValueError, "一次.*仍未通过.*两项条件"):
            extractive_maps._checked_synthesis(None, self.group, self.units, complete)
        self.assertEqual(len(calls), 4)

    def test_bad_review_does_not_trigger_unbounded_repair_or_pass(self):
        invalid = [None, '{"supported":', {}, {"supported": "true", "issues": []},
                   {"supported": 1, "issues": []}, {"supported": True, "issues": ["仍有遗漏"]},
                   {"supported": False, "issues": []}, {"supported": False, "issues": [" "]},
                   {"supported": False, "issues": ["长" * 161]}, {"supported": False, "issues": ["问题"] * 7},
                   {"supported": True, "issues": [], "extra": 1}]
        for response in invalid:
            calls = []
            def complete(llm, system, prompt, schema, **kwargs):
                calls.append(schema)
                return response if "supported" in schema["properties"] else self.draft
            with self.subTest(response=response):
                with self.assertRaisesRegex(ValueError, "对照响应"):
                    extractive_maps._checked_synthesis(None, self.group, self.units, complete)
                self.assertEqual(len(calls), 2)

    def test_blank_slot_in_negative_review_preserves_all_real_issues_and_rejection(self):
        issues = ["主体归属有误", "\n", "缺少前提条件", " "]
        result = extractive_maps._review_stage(None, self.group, self.units, self.draft,
            lambda *args, **kwargs: {"supported": False, "issues": issues})
        self.assertEqual(result, {"supported": False, "issues": ["主体归属有误", "缺少前提条件"]})
        self.assertEqual(issues, ["主体归属有误", "\n", "缺少前提条件", " "])

    def test_review_overbudget_never_drops_tail_or_calls_model(self):
        source = [span(i, "完整原文" * 100 + "。") for i in range(100)]
        units = extractive_maps._make_units(source)
        group = {"members": list(range(len(units))), "core": [0], "conditions": [], "role": "执行动作"}
        calls = []
        with self.assertRaisesRegex(ValueError, "对照超出预算.*未截断"):
            extractive_maps._review_stage(TokenBudget(), group, units, self.draft, lambda *a, **kw: calls.append(a))
        self.assertEqual(calls, [])

    def test_product_does_not_call_diagnostic_review(self):
        model = ExtractiveModel()
        reviews = []
        def complete(llm, system, prompt, schema, **kwargs):
            if "supported" in schema["properties"]:
                reviews.append(prompt)
                return {"supported": False, "issues": [self.issue]}
            if "summary" in schema["properties"]:
                return self.draft
            return model(llm, system, prompt, schema, **kwargs)
        before = copy.deepcopy(self.source)
        nodes, _ = extractive_maps.build_map(TokenBudget(), self.source, complete, "课程")
        self.assertEqual(nodes[1]["sourceBoundStatus"], "summarized")
        self.assertEqual(len(reviews), 0)
        self.assertEqual(self.source, before)


class CrossCourseOrganizationTest(unittest.TestCase):
    def _organization_nodes(self):
        root = {"nodeID": "root", "parentID": None, "navigationRoot": True, "summary": "原始课程标题"}
        methods = [{"nodeID": f"node{i}", "parentID": "root", "sourceBoundStatus": "summarized", "relation": "child",
                    "navigationLabel": f"方法标题{i}", "summary": f"这是方法{i}的既有核心原文案。", "argumentSummary": f"既有详细说明{i}不能丢。",
                    "sourceSpanIDs": [f"source{i}", "shared"], "coveredSourceSpanIDs": [f"source{i}", "shared"],
                    "coreOriginals": [{"text": f"原话{i}", "parts": [{"sourceID": f"source{i}", "startOffset": 0, "endOffset": 3}]}],
                    "conditionOriginals": [{"text": f"条件{i}", "origin": {"sessionID": f"course{i}", "authoredByUser": bool(i % 2)}}]}
                   for i in range(4)]
        return [root] + methods

    def test_final_method_organization_uses_existing_representative_and_preserves_every_source(self):
        nodes = self._organization_nodes(); before = copy.deepcopy(nodes); calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            self.assertEqual(kwargs["max_tokens"], 256)
            self.assertEqual(set(schema["properties"]), {"0", "1", "2", "3"})
            self.assertNotIn("原话0", prompt)  # organization input is not a fabricated evidence claim
            return {"0": 1, "1": 1, "2": 2, "3": 2}
        result, warnings = extractive_maps.organize_method_nodes(None, nodes, complete)
        self.assertEqual(len(calls), 1); self.assertFalse(warnings)
        self.assertEqual(len(result), 3); self.assertEqual(result[0], nodes[0])
        self.assertEqual(result[1]["nodeID"], "node1")
        self.assertEqual(result[1]["summary"], nodes[2]["summary"])
        self.assertEqual(result[1]["navigationLabel"], nodes[2]["navigationLabel"])
        self.assertEqual(result[1]["argumentSummary"], "【方法标题0】\n既有详细说明0不能丢。\n\n【方法标题1】\n既有详细说明1不能丢。")
        for field in ("sourceSpanIDs", "coveredSourceSpanIDs", "coreOriginals", "conditionOriginals"):
            old = {json.dumps(value, sort_keys=True) for node in nodes[1:] for value in node[field]}
            new = {json.dumps(value, sort_keys=True) for node in result[1:] for value in node[field]}
            self.assertEqual(old, new)
        self.assertTrue(all(n["parentID"] == "root" for n in result[1:]))
        self.assertEqual(nodes, before)

    def test_bad_final_organization_keeps_completed_map_without_retry(self):
        nodes = self._organization_nodes()
        for mapping in ({"0": 1, "1": 0, "2": 2, "3": 3}, {"0": 1, "1": 2, "2": 2, "3": 3},
                        {"0": 0, "1": 1, "2": 2}, {"0": False, "1": 1, "2": 2, "3": 3},
                        {"0": 0, "1": 1, "2": 2, "3": 99}, {"0": 0, "1": 1, "2": 2, "3": 3, "summary": "新写正文"}):
            calls = []
            def complete(*args, **kwargs):
                calls.append(args); return mapping
            result, warnings = extractive_maps.organize_method_nodes(None, nodes, complete)
            self.assertEqual(result, nodes); self.assertTrue(warnings); self.assertEqual(len(calls), 1)
        result, warnings = extractive_maps.organize_method_nodes(None, nodes, lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("failed")))
        self.assertEqual(result, nodes); self.assertTrue(warnings)

    def test_small_or_overbudget_final_method_set_does_not_start_organization(self):
        calls = []
        nodes = self._organization_nodes()
        result, warnings = extractive_maps.organize_method_nodes(None, nodes[:4], lambda *a, **kw: calls.append(a))
        self.assertEqual(result, nodes[:4]); self.assertFalse(warnings); self.assertFalse(calls)
        for node in nodes[1:]:
            node["argumentSummary"] = "全部保留的既有论述" * 4000
        result, warnings = extractive_maps.organize_method_nodes(TokenBudget(), nodes, lambda *a, **kw: calls.append(a))
        self.assertEqual(result, nodes); self.assertTrue(warnings); self.assertFalse(calls)

    def test_condition_reselection_is_once_narrow_and_keeps_legal_core_and_conditions(self):
        source = [span(i, f"原始材料{i}包含需要保留的说明。") for i in range(5)]
        other_speaker = str(uuid.uuid4())
        for i in (2, 4):
            source[i]["speakerID"] = other_speaker
        table = [extractive_maps._unit_payload(u) for u in extractive_maps._make_units(source)]
        partitions = [{"stageKey": "A", "members": [0, 1, 2, 3], "role": "执行动作"},
                      {"stageKey": "B", "members": [4], "role": "适用条件"}]
        initial = {"A": {"core": [0], "conditions": [1, 2, 999]},
                   "B": {"core": [4], "conditions": [2, 4, 2]}}
        before = copy.deepcopy(initial)
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append((prompt, schema))
            if len(calls) == 1:
                return initial
            self.assertEqual(set(schema["properties"]), {"A"})
            self.assertEqual(schema["properties"]["A"]["items"]["enum"], [1, 3])
            payload = json.loads(prompt.split("输入：", 1)[1])
            self.assertEqual(payload["stages"]["A"]["lockedCoreKeys"], [0])
            self.assertEqual(payload["stages"]["A"]["retainedConditionKeys"], [1])
            self.assertEqual([u["key"] for u in payload["units"]], [0, 1, 3])
            return {"A": [1, 3]}
        result = extractive_maps._choose_cores(None, partitions, {"A": [0, 1, 2, 3], "B": [4]}, table, complete)
        self.assertEqual(len(calls), 2)
        self.assertEqual([r["core"] for r in result], [[0], [4]])
        self.assertEqual([r["conditions"] for r in result], [[1, 3], [2]])
        self.assertEqual(initial, before)
        self.assertEqual([r["members"] for r in result], [[0, 1, 2, 3], [4]])

    def test_bad_condition_reselection_is_not_retried(self):
        affected = {"A": {"lockedCoreKeys": [0], "retainedConditionKeys": [1], "conditionAllowedKeys": [1, 2]}}
        table = [{"key": k, "text": "真实原文", "speakerKey": 0} for k in range(3)]
        for response in ({"A": [1, 999]}, {"A": [1, 1]}, {"A": [True]}, {"A": [1], "core": [2]}):
            calls = []
            def complete(*args, **kwargs):
                calls.append(args); return response
            with self.assertRaises(ValueError):
                extractive_maps._reselect_conditions(None, affected, table, complete)
            self.assertEqual(len(calls), 1)

    def test_condition_reselection_program_preserves_retained_and_unions_new_beyond_eight(self):
        affected = {"A": {"lockedCoreKeys": [0], "retainedConditionKeys": [1, 2, 3, 4],
                           "conditionAllowedKeys": list(range(1, 13))}}
        table = [{"key": k, "text": "完整原文", "speakerKey": 0} for k in range(13)]
        response = {"A": list(range(5, 13))}
        before = copy.deepcopy(response)
        calls = []
        def complete(*args, **kwargs):
            calls.append(args); return response
        result = extractive_maps._reselect_conditions(None, affected, table, complete)
        self.assertEqual(result["A"], list(range(1, 13)))
        self.assertEqual(response, before)
        self.assertEqual(len(calls), 1)
        # Returned references overlapping retained references are shown once.
        result = extractive_maps._reselect_conditions(None, affected, table, lambda *a, **kw: {"A": [4, 5]})
        self.assertEqual(result["A"], [1, 2, 3, 4, 5])

    def test_first_planning_compacts_notes_but_keeps_changed_reading_and_all_raw(self):
        source = [span(0, "请把这项任物完成。"), span(1, "另一个名称不确定。")]
        for s in source:
            s.update(proofreadText=s["originalText"], proofreadBasis=s["originalText"], proofreadingVersion="context-v1",
                     proofreadUncertainties=["重复疑点说明" * 1000])
        source[0]["proofreadText"] = "请把这项任务完成。"
        units = extractive_maps._make_units(source)
        data = json.loads(extractive_maps._selection_prompt(units).split("输入：", 1)[1])
        self.assertEqual([u["text"] for u in data], [s["originalText"] for s in source])
        self.assertEqual(data[0]["proofreadReadings"], [{"sourcePartIndexes": [0], "wholeSourceReading": True,
                                                        "uncertain": True, "text": "请把这项任务完成。"}])
        self.assertTrue(data[1]["hasUncertainASR"])
        self.assertNotIn("proofreadReadings", data[1])
        self.assertNotIn("重复疑点说明", json.dumps(data, ensure_ascii=False))
        self.assertTrue(all(s["id"] not in json.dumps(data) for s in source))
        # The original span fields and exact original offsets remain available
        # to persistence and click-through, independent of the input encoding.
        self.assertEqual(units[0]["parts"][0]["sourceID"], source[0]["id"])

    def test_default_methodology_roles_and_prompts_do_not_organize_by_lecture_order(self):
        units = extractive_maps._make_units([span(0, "先理解方法的适用条件，然后按实际反馈调整。")])
        prompt = extractive_maps._selection_prompt(units)
        self.assertIn("提炼可迁移的方法论主线", prompt)
        self.assertIn("具体原则、执行动作、适用条件与验证反馈", prompt)
        self.assertIn("不能单独成主题", prompt)
        self.assertIn("不得编造未讲明的方法、因果或执行先后", prompt)
        self.assertFalse({"提出问题", "说明动机", "解释原因", "给出方法", "举例说明", "补充限制", "回顾结论"}
                         & set(extractive_maps.ROLES))
        schema = extractive_maps._partition_schema([0])
        self.assertIn("执行动作", schema["properties"]["stageRoles"]["properties"]["A"]["enum"])
        group = {"members": [0], "core": [0], "conditions": [], "role": "适用条件"}
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            self.assertIn("回答如何理解或执行这个方法", prompt)
            self.assertIn("不硬造执行顺序、因果或未给出的方法", prompt)
            self.assertIn("经验只能按经验表述", prompt)
            return {"navigationLabel": "按条件与反馈调整", "summary": "明确方法的适用条件，并根据实际反馈调整。",
                    "argumentSummary": "将适用条件作为使用方法的前提，结合实际反馈进行调整，不把个人经验直接当作通用保证。"}
        extractive_maps._synthesize_stage(None, group, units, complete)
        self.assertEqual(len(calls), 1)

    def test_principle_and_action_roles_can_merge_as_one_method(self):
        units = extractive_maps._make_units([span(0, "原则是先确认实际条件。"), span(1, "操作时逐项核对这些条件。")])
        groups = [{"members": [0], "core": [0], "conditions": [], "role": "核心原则"},
                  {"members": [1], "core": [1], "conditions": [], "role": "执行动作"}]
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            if "assignments" in schema["properties"]:
                self.assertIn("原则、步骤、依据、条件与反馈应归并", prompt)
                return planned({"0": "A", "1": "A"}, {k: "执行动作" if k == "A" else None for k in extractive_maps.STAGE_KEYS})
            return {"A": {"core": [0], "conditions": [1]}}
        merged = extractive_maps._merge_extractive(None, groups, units, complete)
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["members"], [0, 1])
        self.assertEqual(merged[0]["conditions"], [1])
        self.assertEqual(len(calls), 2)

    def test_known_book_title_kept_and_unknown_title_only_neutralized(self):
        text = "先讨论方法。《明确存在的书》提供例子，然后提到《原稿没有的书》。最后仍要结合条件。"
        source = "讲述者明确提到《明确存在的书》，另一本书的名字没有说清。"
        self.assertEqual(extractive_maps.sanitize_unknown_titles(text, source),
                         "先讨论方法。《明确存在的书》提供例子，然后提到相关书籍（书名待确认）。最后仍要结合条件。")
        self.assertEqual(extractive_maps.sanitize_unknown_titles("这里没有书名，其他内容不动。", source), "这里没有书名，其他内容不动。")

    def test_book_title_requires_exact_original_not_ai_reading_or_simplified_guess(self):
        self.assertEqual(extractive_maps.sanitize_unknown_titles("参考《学习方法》。", "原文是《學習方法》。"),
                         "参考相关书籍（书名待确认）。")
        source = [span(0, "有一本书，但名字听不清，其他方法需要结合条件。")]
        source[0].update(proofreadBasis=source[0]["originalText"], proofreadText="有一本《猜测出来的书》，其他方法需要结合条件。",
                         proofreadingVersion="context-v1", proofreadUncertainties=[])
        units = extractive_maps._make_units(source)
        group = {"members": [0], "core": [0], "conditions": [], "role": "执行动作"}
        calls = []
        def complete(*args, **kwargs):
            calls.append(args)
            return {"navigationLabel": "参考《猜测出来的书》", "summary": "讲述者通过《猜测出来的书》介绍方法，并提醒结合条件。",
                    "argumentSummary": "原文介绍的方法仍需结合实际条件，相关参考材料为《猜测出来的书》。"}
        result = extractive_maps._synthesize_stage(None, group, units, complete)
        self.assertEqual(len(calls), 1)
        self.assertTrue(all("猜测出来的书" not in text for text in result.values()))
        self.assertEqual(units[0]["text"], source[0]["originalText"])

    def test_explicit_manual_book_title_is_valid_source(self):
        source = [span(0, "模糊的名称。")]
        source[0]["correctedText"] = "人工确认书名是《学习与记录》。"
        units = extractive_maps._make_units(source)
        self.assertEqual(extractive_maps.sanitize_unknown_titles("可以参考《学习与记录》。", units[0]["text"]),
                         "可以参考《学习与记录》。")

    def test_global_merge_strips_only_reading_metadata_keeps_all_raw_sources(self):
        source = [span(i, f"来源原文{i}必须完整保留。") for i in range(4)]
        for s in source:
            s.update(proofreadText=s["originalText"], proofreadBasis=s["originalText"], proofreadingVersion="context-v1",
                     proofreadUncertainties=["冗长诊断说明" * 3000])
        units = extractive_maps._make_units(source)
        groups = [{"members": [0, 1], "core": [0], "conditions": [1], "role": "执行动作"},
                  {"members": [2, 3], "core": [2], "conditions": [3], "role": "执行动作"}]
        before = copy.deepcopy(units)
        model = ExtractiveModel()
        result = extractive_maps._merge_extractive(TokenBudget(), groups, units, model)
        data = json.loads(model.calls[0][1].split("输入：", 1)[1])
        self.assertEqual([u["text"] for u in data["units"]], [s["originalText"] for s in source])
        self.assertTrue(all("proofreadReadings" not in u for u in data["units"]))
        self.assertEqual(units, before)
        self.assertEqual(result[0]["members"], [0, 1, 2, 3])
        stage = extractive_maps._stage_payload(result[0], units)
        for unit in stage["units"]:
            self.assertTrue(unit["hasUncertainASR"])
            self.assertNotIn("proofreadReadings", unit)
        self.assertNotIn("冗长诊断说明", json.dumps(stage, ensure_ascii=False))

    def test_inherited_conditions_can_exceed_selection_display_quota(self):
        source = [span(i, f"补充原文{i}包含相应限制。") for i in range(12)]
        units = extractive_maps._make_units(source)
        groups = [{"members": list(range(6)), "core": [0], "conditions": list(range(1, 6)), "role": "执行动作"},
                  {"members": list(range(6, 12)), "core": [6], "conditions": list(range(7, 12)), "role": "执行动作"}]
        model = ExtractiveModel()
        merged = extractive_maps._merge_extractive(TokenBudget(), groups, units, model)
        self.assertEqual(set(merged[0]["conditions"]), set(range(1, 6)) | set(range(7, 12)))
        self.assertEqual(len(merged[0]["conditions"]), 10)
        self.assertEqual(merged[0]["members"], list(range(12)))

    def test_many_groups_fit_one_global_merge_without_redundant_final_merge(self):
        from unittest.mock import patch
        source = [span(i, f"原文材料{i}保持完整。") for i in range(19)]
        units = extractive_maps._make_units(source)
        model = ExtractiveModel()
        # Isolate the merge scheduling: each pre-existing page yields one
        # stage, exactly like cached page outputs; no semantic expectations.
        with patch.object(extractive_maps, "_selection_pages", return_value=iter([[u] for u in units])):
            nodes, _ = extractive_only(TokenBudget(), source, model, "材料")
        global_calls = [c for c in model.calls if "assignments" in c[2]["properties"]
                        and isinstance(json.loads(c[1].split("输入：", 1)[1]), dict)]
        self.assertEqual(len(global_calls), 1)
        self.assertEqual(len(model.calls), 19 * 2 + 2)
        self.assertEqual(set(nodes[0]["coveredSourceSpanIDs"]), {s["id"] for s in source})

    def test_core_choice_uses_complete_raw_evidence_without_proofread_metadata(self):
        source = [span(0, "完整原话需要逐字保留。", {"sessionID": "course-a", "sessionTitle": "来源课程", "authoredByUser": True}),
                  span(1, "后段进一步说明限制条件。", {"sessionID": "course-a", "sessionTitle": "来源课程", "authoredByUser": True})]
        units = extractive_maps._make_units(source)
        table = [extractive_maps._unit_payload(u) for u in units]
        for item in table:
            item["proofreadReadings"] = [{"sourceID": str(uuid.uuid4()), "text": "巨大辅助校订材料" * 3000,
                                          "uncertainties": ["长疑点说明" * 3000]}]
        original = copy.deepcopy(table)
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            payload = json.loads(prompt.split("输入：", 1)[1])
            for sent, raw in zip(payload["units"], original):
                self.assertNotIn("proofreadReadings", sent)
                self.assertEqual(sent, {k: v for k, v in raw.items() if k != "proofreadReadings"})
            self.assertEqual(payload["stages"][0]["conditionAllowedKeys"], [0, 1])
            return {"A": {"core": [0], "conditions": [1]}}
        groups = extractive_maps._choose_cores(TokenBudget(), [{"stageKey": "A", "members": [0, 1], "role": "执行动作"}],
                                               {"A": [0, 1]}, table, complete)
        self.assertEqual(len(calls), 1)
        self.assertEqual(groups[0]["conditions"], [1])
        self.assertEqual(table, original)

    def test_core_choice_batches_stage_protocol_not_evidence_or_cross_stage_conditions(self):
        table = [{"key": i, "text": f"完整来源{i}：" + "说明实际步骤与限制。" * 15,
                  "speakerKey": 0} for i in range(7)]
        partitions = [{"stageKey": stage, "members": [i], "role": "执行动作", "label": f"具体方法{i}"}
                      for i, stage in enumerate(extractive_maps.STAGE_KEYS)]
        allowed = {p["stageKey"]: p["members"] for p in partitions}
        conditions = {stage: list(range(7)) for stage in allowed}
        before = copy.deepcopy((partitions, allowed, table))
        counter = TokenBudget()
        requests = [extractive_maps._core_choice_request([p], {p["stageKey"]: allowed[p["stageKey"]]},
                    {p["stageKey"]: conditions[p["stageKey"]]}, table) for p in partitions]
        cap = max(len(counter.tokenize((extractive_maps.SELECT_SYSTEM + prompt + extractive_maps._json(schema)).encode()))
                  for prompt, schema in requests) + extractive_maps.REPLY_LIMIT + extractive_maps.MARGIN
        class Bounded(TokenBudget):
            def n_ctx(self):
                return cap
        llm = Bounded()
        prompt, schema = extractive_maps._core_choice_request(partitions, allowed, conditions, table)
        self.assertFalse(extractive_maps._fits(llm, extractive_maps.SELECT_SYSTEM, prompt, schema, 1000))
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            self.assertTrue(extractive_maps._fits(llm, system, prompt, schema, kwargs["max_tokens"]))
            payload = json.loads(prompt.split("输入：", 1)[1])
            self.assertEqual(payload["units"], table)  # includes all tail/cross-stage evidence each time
            self.assertEqual(len(payload["stages"]), 1)
            stage = payload["stages"][0]
            self.assertEqual(stage["conditionAllowedKeys"], list(range(7)))
            key = stage["allowedKeys"][0]
            calls.append(stage["stageKey"])
            return {stage["stageKey"]: {"core": [key], "conditions": [(key + 1) % 7]}}
        result = extractive_maps._choose_cores(llm, partitions, allowed, table, complete)
        self.assertEqual(calls, list(extractive_maps.STAGE_KEYS))
        self.assertEqual([g["members"] for g in result], [[i] for i in range(7)])
        self.assertEqual([g["conditions"] for g in result], [[(i + 1) % 7] for i in range(7)])
        self.assertEqual((partitions, allowed, table), before)

    def test_core_choice_output_budget_also_batches_and_rejects_late_missing_stage(self):
        from unittest.mock import patch
        table = [{"key": i, "text": f"完整来源{i}。", "speakerKey": 0} for i in range(5)]
        partitions = [{"stageKey": stage, "members": [i], "role": "执行动作"}
                      for i, stage in enumerate(extractive_maps.STAGE_KEYS[:5])]
        allowed = {p["stageKey"]: p["members"] for p in partitions}
        calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            keys = list(schema["properties"])
            calls.append(keys)
            return {stage: {"core": allowed[stage], "conditions": []} for stage in keys}
        with patch.object(extractive_maps, "_choice_reply_fits", side_effect=lambda llm, a, c: len(a) <= 2):
            result = extractive_maps._choose_cores(TokenBudget(), partitions, allowed, table, complete)
            self.assertEqual(calls, [["A", "B"], ["C", "D"], ["E"]])
            self.assertEqual(len(result), 5)
            calls.clear()
            def invalid_late(*args, **kwargs):
                value = complete(*args, **kwargs)
                return {} if len(calls) == 3 else value
            with self.assertRaisesRegex(ValueError, "缺少固定阶段"):
                extractive_maps._choose_cores(TokenBudget(), partitions, allowed, table, invalid_late)

    def test_core_choice_preflights_all_batches_before_any_model_call(self):
        from unittest.mock import patch
        table = [{"key": i, "text": "全部原文不能裁掉", "speakerKey": 0} for i in range(2)]
        partitions = [{"stageKey": stage, "members": [i], "role": "执行动作"}
                      for i, stage in enumerate(["A", "B"])]
        allowed = {p["stageKey"]: p["members"] for p in partitions}
        calls = []
        # First stage would fit, second cannot: never spend inference on an
        # ultimately unrepresentable operation, or publish a partial map.
        with patch.object(extractive_maps, "_fits", side_effect=lambda llm, system, prompt, schema, reply: set(schema["properties"]) == {"A"}):
            with self.assertRaisesRegex(ValueError, "单个阶段.*未截断"):
                extractive_maps._choose_cores(TokenBudget(), partitions, allowed, table, lambda *a, **kw: calls.append(a))
        self.assertFalse(calls)

    def test_selection_pages_checks_next_single_stage_protocol_before_planning(self):
        from unittest.mock import patch
        units = extractive_maps._make_units([span(i, f"来源{i}的完整方法与尾部限制不能丢。") for i in range(5)])
        before = copy.deepcopy(units)
        real_fits = extractive_maps._fits
        def fits(llm, system, prompt, schema, reply):
            if system == extractive_maps.PLAN_SYSTEM:
                return True  # planning can fit more than the next protocol
            payload = json.loads(prompt.split("输入：", 1)[1])
            self.assertEqual(reply, extractive_maps.REPLY_LIMIT + 80)
            self.assertEqual(payload["stages"][0]["members"], [u["key"] for u in payload["units"]])
            return len(payload["units"]) <= 2 and real_fits(llm, system, prompt, schema, reply)
        with patch.object(extractive_maps, "_fits", side_effect=fits):
            pages = list(extractive_maps._selection_pages(TokenBudget(), units))
        self.assertEqual([[u["key"] for u in page] for page in pages], [[0, 1], [2, 3], [4]])
        self.assertEqual([u for page in pages for u in page], before)
        self.assertEqual(units, before)
        # Even the first indivisible unit may not fit the selection protocol.
        # Refuse before producing any page, not after expensive model planning.
        with patch.object(extractive_maps, "_single_stage_choice_fits", return_value=False):
            with self.assertRaisesRegex(ValueError, "原文未截断"):
                next(extractive_maps._selection_pages(TokenBudget(), units))

    def test_proofread_aid_never_replaces_raw_offsets_and_stale_basis_is_ignored(self):
        source = [span(0, "请把这项任物完成。")]
        source[0].update(proofreadText="请把这项任务完成。", proofreadBasis=source[0]["originalText"],
                         proofreadingVersion="context-v1", proofreadUncertainties=["名称仍待确认。"])
        unit = extractive_maps._make_units(source)[0]
        payload = extractive_maps._unit_payload(unit)
        self.assertEqual(unit["text"], source[0]["originalText"])
        self.assertEqual(payload["proofreadReadings"][0]["text"], "请把这项任务完成。")
        self.assertTrue(payload["proofreadReadings"][0]["wholeSourceReading"])
        part = unit["parts"][0]
        self.assertEqual(source[0]["originalText"][part["startOffset"]:part["endOffset"]], unit["text"])
        source[0]["proofreadBasis"] = "过期原文"
        self.assertNotIn("proofreadReadings", extractive_maps._unit_payload(extractive_maps._make_units(source)[0]))

    def test_human_corrected_authored_and_unchanged_text_do_not_get_ai_reading(self):
        for kind in ("corrected", "authored", "unchanged"):
            source = [span(0, "需要完成任务。")]
            source[0].update(proofreadText="需要完成任务。", proofreadBasis=source[0]["originalText"],
                             proofreadingVersion="context-v1", proofreadUncertainties=[])
            if kind == "corrected":
                source[0]["correctedText"] = "这是人工写的内容。"
            if kind == "authored":
                source[0]["origin"] = {"sessionID": "a", "sessionTitle": "手写", "authoredByUser": True}
            self.assertNotIn("proofreadReadings", extractive_maps._unit_payload(extractive_maps._make_units(source)[0]))

    def test_uncertainty_does_not_block_one_pass_stage_summary(self):
        source = [span(0, "这里有一个尚不清楚的名称，但方法可以先确认适用条件。")]
        source[0].update(proofreadText=source[0]["originalText"], proofreadBasis=source[0]["originalText"],
                         proofreadingVersion="context-v1", proofreadUncertainties=["名称不能确定，不作猜测。"])
        model = ExtractiveModel(); generated = []
        def complete(llm, system, prompt, schema, **kwargs):
            self.assertNotIn("supported", schema["properties"])
            if "summary" not in schema["properties"]:
                return model(llm, system, prompt, schema, **kwargs)
            generated.append(prompt)
            data = json.loads(prompt.split("输入：", 1)[1])
            self.assertTrue(data["units"][0]["hasUncertainASR"])
            return {"navigationLabel": "确认适用条件", "summary": "名称尚不明确时，仍可先确认方法的适用条件。", "argumentSummary": "保留名称疑点，不猜测其含义；继续整理明确提到的方法与适用条件。"}
        nodes, _ = extractive_maps.build_map(None, source, complete, "课程")
        self.assertEqual(len(generated), 1)
        self.assertEqual(nodes[1]["coreOriginals"][0]["text"], source[0]["originalText"])

    def test_single_course_local_and_global_share_methodology_goal(self):
        units = extractive_maps._make_units([span(0, "先理解问题。"), span(1, "再结合条件处理。")])
        prompt = extractive_maps._selection_prompt(units)
        self.assertIn(extractive_maps.METHODOLOGY_GOAL, prompt)
        self.assertNotIn(extractive_maps.MULTI_COURSE_GOAL, prompt)
        groups = [{"members": [0], "core": [0], "conditions": [], "role": "待解问题"},
                  {"members": [1], "core": [1], "conditions": [], "role": "执行动作"}]
        model = ExtractiveModel()
        extractive_maps._merge_extractive(None, groups, units, model)
        self.assertIn(extractive_maps.METHODOLOGY_GOAL, model.calls[0][1])

    def test_multiple_courses_share_goal_without_more_material(self):
        units = extractive_maps._make_units([span(0, "甲提出一项方法。", {"sessionID": "a", "sessionTitle": "甲"}),
                                            span(1, "乙给出相关条件。", {"sessionID": "b", "sessionTitle": "乙"})])
        prompt = extractive_maps._selection_prompt(units)
        single_mode = extractive_maps._selection_prompt(units, multi_course=False)
        self.assertIn(extractive_maps.MULTI_COURSE_GOAL, prompt)
        self.assertEqual(json.loads(prompt.split("输入：", 1)[1]), json.loads(single_mode.split("输入：", 1)[1]))
        self.assertIn("最多涉及3门课程/用户类别", prompt)
        groups = [{"members": [0], "core": [0], "conditions": [], "role": "待解问题"},
                  {"members": [1], "core": [1], "conditions": [], "role": "执行动作"}]
        model = ExtractiveModel()
        extractive_maps._merge_extractive(None, groups, units, model)
        self.assertIn(extractive_maps.MULTI_COURSE_GOAL, model.calls[0][1])
        self.assertEqual(len(model.calls), 2)

    def test_same_course_multiple_speakers_or_user_authorship_is_not_multi_course(self):
        origin = {"sessionID": "course", "sessionTitle": "同一课"}
        source = [span(0, "讲师的文字。", origin), span(1, "用户的思考。", dict(origin, authoredByUser=True)),
                  dict(span(2, "另一讲者的话。", origin), speakerID=str(uuid.uuid4()))]
        units = extractive_maps._make_units(source)
        self.assertFalse(extractive_maps._has_multiple_courses(units))
        prompt = extractive_maps._selection_prompt(units)
        self.assertNotIn(extractive_maps.MULTI_COURSE_GOAL, prompt)
        self.assertIn("绝不能冒充讲师观点", prompt)
        self.assertTrue(units[1]["origin"]["authoredByUser"])

    def test_page_inherits_whole_input_course_mode_even_when_page_has_one_course(self):
        from unittest.mock import patch
        source = [span(0, "甲的材料。", {"sessionID": "a", "sessionTitle": "甲"}),
                  span(1, "乙的材料。", {"sessionID": "b", "sessionTitle": "乙"})]
        units = extractive_maps._make_units(source)
        model = ExtractiveModel()
        def complete(llm, system, prompt, schema, **kwargs):
            if "assignments" in schema["properties"]:
                return model(llm, system, prompt, schema, **kwargs)
            model.calls.append((system, prompt, schema))
            return {stage: {"core": field["properties"]["core"]["items"]["enum"], "conditions": []}
                    for stage, field in schema["properties"].items()}
        with patch.object(extractive_maps, "_selection_pages", return_value=iter([[units[0]], [units[1]]])):
            extractive_only(None, source, complete, "综合")
        planning = [call for call in model.calls if "assignments" in call[2]["properties"]]
        self.assertEqual(len(planning), 3)  # two existing local calls and existing merge
        self.assertTrue(all(extractive_maps.MULTI_COURSE_GOAL in call[1] for call in planning))


class MethodBranchExpansionTest(unittest.TestCase):
    def fixture(self):
        origin = {"sessionID": str(uuid.uuid4()), "sessionTitle": "原课程", "authoredByUser": True}
        source = [span(0, "先确认实际条件，再决定是否开始执行。", origin),
                  span(1, "执行后核对结果，发现偏差时需要调整。", origin)]
        ids = [s["id"] for s in source]
        nodes = [{"nodeID": str(uuid.uuid4()), "navigationRoot": True, "parentID": None, "summary": "课程"}]
        nodes.append({"nodeID": str(uuid.uuid4()), "parentID": nodes[0]["nodeID"], "kind": "主线", "sourceBoundStatus": "summarized",
                      "sourceSpanIDs": ids, "coveredSourceSpanIDs": ids, "navigationLabel": "按条件执行并反馈调整",
                      "summary": "先确认条件，执行后依据反馈调整。", "argumentSummary": "保留原来全部详细论述。"})
        branches = [{"navigationLabel": "先核对适用条件", "summary": "开始执行前确认实际条件，只有条件适合时再决定是否开始，而不是直接照搬行动。", "sourceKeys": [0]},
                    {"navigationLabel": "根据结果调整", "summary": "执行以后核对实际结果，把发现的偏差作为调整依据，让行动和反馈衔接起来。", "sourceKeys": [1]}]
        return source, nodes, branches

    def test_adds_concrete_children_with_exact_sources_and_no_parent_rewrite(self):
        source, nodes, branches = self.fixture(); original = copy.deepcopy((source, nodes)); calls = []
        def complete(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            data = json.loads(prompt.split("输入：", 1)[1])
            self.assertEqual([u["text"] for u in data["units"]], [s["originalText"] for s in source])
            self.assertTrue(all(u["origin"]["authoredByUser"] for u in data["units"]))
            self.assertIn("不是事实依据", prompt)
            self.assertIn("不重复整条主方法", prompt)
            return {"branches": branches}
        result, warnings = extractive_maps.expand_method_branches(None, nodes, source, complete)
        self.assertFalse(warnings); self.assertEqual(len(calls), 1)
        self.assertEqual(result[:2], nodes); self.assertEqual(len(result), 4)
        self.assertEqual((source, nodes), original)
        for index, child in enumerate(result[2:]):
            self.assertEqual(child["kind"], "支线")
            self.assertEqual(child["parentID"], nodes[1]["nodeID"])
            self.assertEqual(child["sourceSpanIDs"], [source[index]["id"]])
            quote = child["coreOriginals"][0]
            self.assertEqual(quote["text"], source[index]["originalText"])
            part = quote["parts"][0]
            self.assertEqual(source[index]["originalText"][part["startOffset"]:part["endOffset"]], quote["text"])
        self.assertEqual(result[1]["coveredSourceSpanIDs"], [s["id"] for s in source])

    def test_invalid_second_child_cannot_partially_apply_or_cross_source(self):
        source, nodes, branches = self.fixture()
        for wrong in ([999], [True], [], [1, 1]):
            invalid = copy.deepcopy(branches); invalid[1]["sourceKeys"] = wrong
            calls = []
            def complete(*args, **kwargs):
                calls.append(args); return {"branches": invalid}
            result, warnings = extractive_maps.expand_method_branches(None, nodes, source, complete)
            self.assertEqual(result, nodes); self.assertTrue(warnings); self.assertEqual(len(calls), 1)

    def test_bad_count_text_response_or_missing_source_fails_without_retry(self):
        source, nodes, branches = self.fixture()
        for value in ({"branches": []}, {"branches": branches * 3}, {"branches": [dict(branches[0], summary="空")]},
                      {"branches": [dict(branches[0], navigationLabel="过长" * 20)]}, '{"branches":'):
            calls = []
            def complete(*args, **kwargs):
                calls.append(args); return value
            result, warnings = extractive_maps.expand_method_branches(None, nodes, source, complete)
            self.assertEqual(result, nodes); self.assertTrue(warnings); self.assertEqual(len(calls), 1)
        result, warnings = extractive_maps.expand_method_branches(None, nodes, source[:1], lambda *a, **kw: self.fail("不能发送缺失来源"))
        self.assertEqual(result, nodes); self.assertTrue(warnings)

    def test_complete_overbudget_method_preserves_raw_and_existing_children_are_not_replaced(self):
        source, nodes, branches = self.fixture()
        source[0]["originalText"] = "连续的完整原文没有允许的分割标点" * 3000
        result, warnings = extractive_maps.expand_method_branches(TokenBudget(), nodes, source, lambda *a, **kw: self.fail("不能截尾后调用"))
        self.assertEqual(result, nodes); self.assertTrue(warnings)
        existing = nodes + [{"nodeID": "human-child", "parentID": nodes[1]["nodeID"], "summary": "已有手写内容"}]
        result, warnings = extractive_maps.expand_method_branches(None, existing, source, lambda *a, **kw: self.fail("不能覆盖已有孩子"))
        self.assertEqual(result, existing); self.assertFalse(warnings)

    def test_production_default_calls_new_layer_after_old_stage_calls(self):
        source, _, branches = self.fixture()
        model = ExtractiveModel(); kinds = []
        def complete(llm, system, prompt, schema, **kwargs):
            if "branches" in schema["properties"]:
                kinds.append("children"); return {"branches": branches}
            if "summary" in schema["properties"]:
                kinds.append("method")
                return {"navigationLabel": "根据条件与反馈行动", "summary": "先确认条件再执行，随后核对结果并调整。", "argumentSummary": "完整原文保留适用条件和执行后的反馈步骤。"}
            kinds.append("old")
            return model(llm, system, prompt, schema, **kwargs)
        result, warnings = extractive_maps.build_map(None, source, complete, "课程")
        self.assertEqual(kinds, ["old", "old", "method", "children"])
        self.assertEqual(len([n for n in result if n.get("kind") == "支线"]), 2)


if __name__ == "__main__":
    unittest.main()
