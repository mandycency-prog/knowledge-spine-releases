import copy
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import local_pipeline as pipeline
import quote_evidence as quotes
from quote_test_support import quote_response


class TopicRolesTest(unittest.TestCase):
    def note(self):
        return {"sourceSpanIDs": ["s"], "sourceText": "方法只在条件稳定时适用。", "summary": "稳定条件下使用方法"}

    def stage(self, title="稳定条件下使用方法"):
        return dict(self.note(), summary=title, argumentSummary="条件不稳定时不能套用。", _coverage=[0], relationToPrevious="给出方法")

    def test_new_root_role_is_program_owned_and_cannot_remove_same_named_child(self):
        title = "方法的适用条件"
        payload = {"center": {"summary": title, "argumentSummary": "模型写入不应保留的总论", "evidenceIndex": 0, "semanticRole": "assertion"}}
        stage = dict(self.stage(title), semanticRole="topic")
        with patch.object(pipeline, "request_global_outline", return_value=(payload, [stage])), \
             patch.object(pipeline, "verify_discourse_semantics"):
            nodes = pipeline.consolidate_thematic_mind_map(None, [self.note()])
        self.assertEqual(len(nodes), 2)
        self.assertEqual(nodes[0]["semanticRole"], "topic")
        self.assertEqual(nodes[0]["argumentSummary"], "")
        self.assertEqual(nodes[1]["semanticRole"], "assertion")
        self.assertEqual(nodes[1]["argumentSummary"], stage["argumentSummary"])

    def test_single_stage_fallback_keeps_fact_and_assertion_role(self):
        stage = self.stage()
        with patch.object(pipeline, "request_global_outline", return_value=({"center": {}}, [stage])), \
             patch.object(pipeline, "verify_discourse_semantics"):
            nodes = pipeline.consolidate_thematic_mind_map(None, [self.note()])
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0]["semanticRole"], "assertion")
        self.assertEqual(nodes[0]["summary"], stage["summary"])
        self.assertEqual(nodes[0]["argumentSummary"], stage["argumentSummary"])

    def test_children_incomplete_scope_and_topic_extra_assertions_are_rejected(self):
        root = {"summary": "方法的适用条件", "semanticRole": "topic", "parentID": None, "relation": "root", "argumentSummary": ""}
        for changed, coverage in (({"parentID": "parent"}, [[0]]), ({"relation": "child"}, [[0]]),
                                  ({"argumentSummary": "方法永远有效"}, [[0]]), ({}, [[]])):
            with patch.object(pipeline, "structured_completion") as model:
                with self.assertRaisesRegex(ValueError, "主题角色"):
                    pipeline.verify_discourse_semantics(None, [dict(root, **changed)], [self.note()], coverage)
            model.assert_not_called()

    def test_missing_role_defaults_to_full_assertion_audit(self):
        node = {"summary": "条件稳定才适用", "argumentSummary": "条件改变时需要重新检验。", "coveredSourceSpanIDs": ["s"]}
        judged = []
        def model(llm, system, prompt, schema, **kwargs):
            self.assertNotIn("scopeNotes", prompt)
            if "verdict" in schema["properties"]:
                self.assertEqual(next(iter(schema["properties"])), "verdict")
                judged.append(json.loads(prompt.split("输入：", 1)[1])["claimQuote"])
            return quote_response(prompt, schema)
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, [node], [self.note()], [[0]])
        self.assertEqual(judged, [node["summary"], node["argumentSummary"]])
        self.assertNotIn("semanticRole", node)

    def test_topic_repair_cannot_change_role_or_introduce_extra_argument(self):
        node = {"nodeID": "root", "summary": "为何方法无条件有效", "semanticRole": "topic", "parentID": None,
                "relation": "root", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]}
        child = {"nodeID": "child", "summary": "稳定条件下使用方法", "semanticRole": "assertion",
                 "parentID": "root", "relation": "child", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]}
        repairs, judgments = [], []
        def model(llm, system, prompt, schema, **kwargs):
            if "summary" in schema["properties"]:
                repairs.append(schema)
                return {"summary": "方法的适用条件", "semanticRole": "assertion", "argumentSummary": "偷偷新增因果"}
            if "verdict" in schema["properties"] and "scopeNotes" in prompt:
                judgments.append(json.loads(prompt.split("输入：", 1)[1]))
            return quote_response(prompt, schema, verdict="contradicted" if "为何方法无条件有效" in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, [node, child], [self.note()], [[0], [0]])
        self.assertEqual(len(repairs), 1)
        self.assertEqual(set(repairs[0]["properties"]), {"summary"})
        self.assertTrue(all("scopeNotes" in item for item in judgments))
        self.assertEqual(node["semanticRole"], "topic")
        self.assertEqual(node["argumentSummary"], "")

    def test_topic_standard_checks_presuppositions_and_all_scope_without_extra_calls(self):
        records = [{"id": "a", "text": "只减少了部分等待，仍然需要排队。"}]
        scope = [{"summary": "定位排队产生的原因", "argumentSummary": "比较不同环节的等待。"},
                 {"summary": "修改部分等待环节", "argumentSummary": "没有彻底取消排队。"}]
        original = copy.deepcopy((records, scope))
        calls = []
        def model(llm, system, prompt, schema, **kwargs):
            calls.append(prompt)
            if "verdict" in schema["properties"]:
                self.assertEqual(list(schema["properties"]), ["claimQuote", "evidenceQuotes", "assumptions", "reason", "verdict"])
                data = json.loads(prompt.split("输入：", 1)[1])
                self.assertEqual(data["scopeNotes"], scope)
                self.assertIn("预设", prompt)
                self.assertIn("不能替代sourceContexts", prompt)
                self.assertIn("旁题", prompt)
                self.assertIn("全部", prompt)
            return quote_response(prompt, schema, verdict="contradicted")
        result = quotes.verify_topic(None, model, "为何彻底消除等待", records, scope)
        self.assertEqual(len(calls), 2)
        self.assertEqual(result["judgments"][0]["verdict"], "contradicted")
        self.assertEqual(result["judgments"][0]["sourceSpanIDs"], ["a"])
        self.assertEqual((records, scope), original)

    def test_failed_old_assertion_cannot_repair_itself_into_a_topic(self):
        node = {"summary": "任何时候方法都有效", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]}
        seen = []
        def model(llm, system, prompt, schema, **kwargs):
            if "summary" in schema["properties"]:
                return {"summary": "稳定条件下使用方法", "argumentSummary": "", "semanticRole": "topic"}
            if "verdict" in schema["properties"]:
                seen.append(system)
                self.assertNotIn("scopeNotes", prompt)
            return quote_response(prompt, schema, verdict="contradicted" if "任何时候方法都有效" in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, [node], [self.note()], [[0]])
        self.assertEqual(len(seen), 2)
        self.assertNotIn("semanticRole", node)

    def test_no_partial_publish_when_a_child_fails(self):
        nodes = [{"nodeID": "root", "summary": "方法的适用条件", "semanticRole": "topic", "parentID": None,
                  "relation": "root", "argumentSummary": "", "sourceSpanIDs": ["s"], "coveredSourceSpanIDs": ["s"]},
                 {"nodeID": "child", "summary": "任何时候方法都有效", "semanticRole": "assertion", "parentID": "root",
                  "relation": "child", "argumentSummary": "", "sourceSpanIDs": ["s"], "coveredSourceSpanIDs": ["s"]}]
        original = copy.deepcopy(nodes)
        def model(llm, system, prompt, schema, **kwargs):
            if "summary" in schema["properties"]:
                return {"summary": "任何时候方法都有效", "argumentSummary": "", "semanticRole": "topic"}
            return quote_response(prompt, schema, verdict="contradicted" if "任何时候方法都有效" in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            with self.assertRaises(pipeline.DiscourseSemanticError):
                pipeline.verify_discourse_semantics(None, nodes, [self.note()], [[0], [0]])
        self.assertEqual(nodes, original)

    def test_topic_without_stages_and_foreign_stage_are_rejected(self):
        root = {"nodeID": "root", "summary": "方法的适用条件", "semanticRole": "topic", "parentID": None,
                "relation": "root", "argumentSummary": ""}
        with self.assertRaisesRegex(ValueError, "实质阶段"):
            pipeline.verify_discourse_semantics(None, [root], [self.note()], [[0]])
        child = {"nodeID": "child", "summary": "稳定条件才适用", "parentID": "different-root", "relation": "child"}
        with self.assertRaisesRegex(ValueError, "归属"):
            pipeline.verify_discourse_semantics(None, [root, child], [self.note()], [[0], [0]])

    def test_topic_uses_final_stages_without_reordering_identity_or_reloading_old_notes(self):
        nodes = [{"nodeID": "root", "summary": "方法的适用条件", "semanticRole": "topic", "parentID": None,
                  "relation": "root", "argumentSummary": "", "coveredSourceSpanIDs": ["a", "b"]},
                 {"nodeID": "first", "summary": "任何条件下都适用", "parentID": "root", "relation": "child",
                  "argumentSummary": "", "coveredSourceSpanIDs": ["a"]},
                 {"nodeID": "second", "summary": "条件变化后再检验", "parentID": "root", "relation": "child",
                  "argumentSummary": "", "coveredSourceSpanIDs": ["b"]}]
        notes = [{"summary": "旧笔记" * 9000, "sourceText": "稳定条件下才能使用。", "sourceSpanIDs": ["a"]},
                 {"summary": "旧笔记二", "sourceText": "条件变化以后重新检验。", "sourceSpanIDs": ["b"]}]
        observed = []
        def model(llm, system, prompt, schema, **kwargs):
            if "summary" in schema["properties"]:
                return {"summary": "稳定条件下才能使用", "argumentSummary": ""}
            if "verdict" in schema["properties"]:
                data = json.loads(prompt.split("输入：", 1)[1])
                observed.append(data["claimQuote"])
                if "scopeNotes" in data:
                    self.assertEqual(data["scopeNotes"], [{"summary": "稳定条件下才能使用", "argumentSummary": ""},
                                                        {"summary": "条件变化后再检验", "argumentSummary": ""}])
                    self.assertNotIn("旧笔记", prompt)
            return quote_response(prompt, schema, verdict="contradicted" if "任何条件下都适用" in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            pipeline.verify_discourse_semantics(None, nodes, notes, [[0, 1], [0], [1]])
        self.assertEqual([n["nodeID"] for n in nodes], ["root", "first", "second"])
        self.assertEqual([n["parentID"] for n in nodes], [None, "root", "root"])
        self.assertEqual(nodes[1]["summary"], "稳定条件下才能使用")
        self.assertEqual(nodes[2]["sourceSpanIDs"], ["b"])
        self.assertEqual(observed[-1], nodes[0]["summary"])

    def test_failed_topic_does_not_commit_previously_repaired_child(self):
        nodes = [{"nodeID": "root", "summary": "错误的中心主题", "semanticRole": "topic", "parentID": None,
                  "relation": "root", "argumentSummary": "", "coveredSourceSpanIDs": ["s"]},
                 {"nodeID": "child", "summary": "任何条件下都适用", "parentID": "root", "relation": "child",
                  "argumentSummary": "", "coveredSourceSpanIDs": ["s"]}]
        original = copy.deepcopy(nodes)
        def model(llm, system, prompt, schema, **kwargs):
            if "summary" in schema["properties"]:
                return ({"summary": "错误的中心主题"} if "只修正中心主题summary" in prompt else
                        {"summary": "稳定条件才适用", "argumentSummary": ""})
            return quote_response(prompt, schema, verdict="contradicted" if
                                  "任何条件下都适用" in prompt or "错误的中心主题" in prompt else "supported")
        with patch.object(pipeline, "structured_completion", side_effect=model):
            with self.assertRaises(pipeline.DiscourseSemanticError):
                pipeline.verify_discourse_semantics(None, nodes, [self.note()], [[0], [0]])
        self.assertEqual(nodes, original)

    def test_unresolved_topic_can_pass_but_incidental_scope_rejection_is_not_overridden(self):
        records = [{"id": "a", "text": "我们还在比较修理和更换，尚未选定方案。"}]
        scope = [{"summary": "比较修理和更换", "argumentSummary": "讨论不同选择的条件。"}]
        for verdict in ("supported", "unknown"):
            def model(llm, system, prompt, schema, **kwargs):
                if "verdict" in schema["properties"]:
                    self.assertIn("不要求课程已经得出最终答案", prompt)
                    self.assertIn("主次", prompt)
                return quote_response(prompt, schema, verdict=verdict)
            result = quotes.verify_topic(None, model, "修理还是更换的取舍", records, scope)
            self.assertEqual(result["judgments"][0]["verdict"], verdict)

    def test_oversize_scope_fails_without_truncating_tail_or_judge_call(self):
        records = [{"id": "a", "text": "具体方法仍需选择。"}]
        scope = [{"summary": "讨论" * 2000, "argumentSummary": "尾段限制必须保留。"}]
        llm = SimpleNamespace(tokenize=lambda b: list(b), n_ctx=lambda: 8192)
        calls = []
        def model(llm, system, prompt, schema, **kwargs):
            calls.append(schema)
            self.assertIn("evidence", schema["properties"])
            return quote_response(prompt, schema)
        result = quotes.verify_topic(llm, model, "方法选择", records, scope)
        self.assertEqual(len(calls), 1)
        self.assertEqual(result["judgments"][0]["verdict"], "unknown")
        self.assertIn("预算", result["judgments"][0]["reason"])
        self.assertTrue(scope[0]["argumentSummary"].endswith("保留。"))


if __name__ == "__main__":
    unittest.main()
