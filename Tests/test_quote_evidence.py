import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
from quote_evidence import ManuscriptIndex, QuoteError, judge_claim, verify_node


class ExactQuoteProtocolTests(unittest.TestCase):
    def test_unique_quote_programmatically_returns_true_sources(self):
        records = [{"id": "a", "sequence": 1, "text": "这个方法不是普遍"},
                   {"id": "b", "sequence": 2, "text": "有效，而是需要满足条件。"}]
        original = copy.deepcopy(records)
        match = ManuscriptIndex(records).locate("这个方法不是普遍有效，而是需要满足条件。")
        self.assertEqual(match.source_ids, ("a", "b"))
        self.assertEqual(records, original)

    def test_traditional_simplified_and_fabricated_quotes_rejected(self):
        index = ManuscriptIndex([{"id": "a", "text": "這個方法不一定有效。"}])
        self.assertEqual(index.locate("這個方法不一定有效。").source_ids, ("a",))
        for quote in ("这个方法不一定有效。", "這個方法一定有效。", "不存在的文字。"):
            with self.assertRaises(QuoteError):
                index.locate(quote)

    def test_negation_prefix_condition_suffix_and_same_sentence_repeat(self):
        for text, quote in (("这个方法并不能提高效率。", "提高效率。"),
                            ("方法有效，但只限满足条件的人。", "方法有效"),
                            ("如果条件不满足，那么方法不能使用。", "那么方法不能使用。"),
                            ("不是成功成功就意味着长期成功。", "成功")):
            with self.assertRaises(QuoteError):
                ManuscriptIndex([{"id": "a", "text": text}]).locate(quote)

    def test_duplicate_sentence_is_not_silently_assigned_to_first_source(self):
        index = ManuscriptIndex([{"id": "a", "text": "这个方法需要练习。"}, {"id": "b", "text": "这个方法需要练习。"}])
        with self.assertRaisesRegex(QuoteError, "exactly once"):
            index.locate("这个方法需要练习。")

    def test_adjacent_condition_and_speaker_context_are_visible(self):
        index = ManuscriptIndex([{"id": "a", "text": "以下只是受访者的看法。方法非常有效。但不适用于缺少基础的人。"}])
        match = index.locate("方法非常有效。")
        self.assertIn("受访者", match.context)
        self.assertIn("不适用于", match.context)

    def test_noncontiguous_sources_cannot_be_stitched_into_quote(self):
        index = ManuscriptIndex([{"id": "a", "sequence": 1, "text": "这个方法"}, {"id": "b", "sequence": 3, "text": "一定有效。"}])
        with self.assertRaises(QuoteError):
            index.locate("这个方法一定有效。")

    def test_neighbour_context_stops_at_both_source_gaps(self):
        index = ManuscriptIndex([{"id": "a", "sequence": 1, "text": "这不是"},
                                 {"id": "b", "sequence": 3, "text": "在满足条件时，可以使用。"},
                                 {"id": "c", "sequence": 5, "text": "但另一个例子不成立。"}])
        match = index.recover("可以使用。")
        self.assertEqual(match.context, "在满足条件时，可以使用。")
        self.assertEqual(match.source_ids, ("b",))
        self.assertNotIn("不是", match.context)
        self.assertNotIn("另一个", match.context)

    def test_decimal_number_is_not_a_sentence_boundary(self):
        index = ManuscriptIndex([{"id": "a", "text": "测量结果不是131.8，而是另一个数。"}])
        with self.assertRaises(QuoteError):
            index.locate("8，而是另一个数。")
        self.assertEqual(len(index.sentences()), 1)

    def test_closing_quote_does_not_become_next_speakers_prefix(self):
        index = ManuscriptIndex([{"id": "a", "text": "有人说：‘这个办法无条件有效。’"},
                                 {"id": "b", "text": "我不同意这个观点。"}])
        self.assertEqual(index.locate("我不同意这个观点。").source_ids, ("b",))
        self.assertIn("有人说", index.locate("我不同意这个观点。").context)

    def test_judge_cannot_replace_claim_with_an_added_premise(self):
        index = ManuscriptIndex([{"id": "a", "text": "过程很费力，但任务完成得很快。"}])
        match = index.locate(index.text)
        def model(*args, **kwargs):
            return {"verdict": "contradicted", "claimQuote": "任务过程很轻松", "evidenceQuotes": [index.text],
                    "assumptions": [], "canBothBeTrue": False, "reason": "费力不是轻松"}
        with self.assertRaisesRegex(QuoteError, "changed"):
            judge_claim(None, model, "任务完成得很快", [match], index)

    def test_added_assumption_cannot_be_counterevidence(self):
        index = ManuscriptIndex([{"id": "a", "text": "过程很费力，但任务完成得很快。"}])
        for verdict in ("supported", "contradicted"):
            def model(*args, **kwargs):
                return {"verdict": verdict, "claimQuote": "任务完成得很快", "evidenceQuotes": [index.text],
                        "assumptions": ["完成快意味着过程轻松"], "reason": "存在额外解释"}
            result = judge_claim(None, model, "任务完成得很快", [index.locate(index.text)], index)
            self.assertEqual(result["verdict"], "unknown")

    def test_unique_partial_quote_expansion_is_explicit_and_final_quote_strict(self):
        index = ManuscriptIndex([{"id": "a", "text": "我并不赞成全部取消，只赞成减少无效步骤。"}])
        requested = "只赞成减少无效步骤。"
        with self.assertRaises(QuoteError):
            index.locate(requested)
        match = index.recover(requested)
        self.assertTrue(match.expanded)
        self.assertEqual(match.requested_quote, requested)
        self.assertEqual(index.text[match.requested_start:match.requested_end], requested)
        self.assertEqual(match.text, index.text)
        self.assertEqual(index.locate(match.text).source_ids, ("a",))

    def test_expansion_never_repairs_changed_ambiguous_or_discontinuous_text(self):
        for records, requested in (([{"id": "a", "text": "不是有效，而是无效。"}], "不是有用"),
                                   ([{"id": "a", "text": "需要条件。"}, {"id": "b", "text": "需要条件。"}], "需要条件"),
                                   ([{"id": "a", "sequence": 1, "text": "不是"}, {"id": "b", "sequence": 3, "text": "有效。"}], "不是有效")):
            with self.assertRaises(QuoteError):
                ManuscriptIndex(records).recover(requested)

    def test_partial_retrieval_passes_only_expanded_context_to_judge(self):
        records = [{"id": "a", "text": "不能提高效率，只有满足条件后才可能有效。"}]
        def model(llm, system, prompt, schema, **kwargs):
            if "evidence" in schema["properties"]:
                return {"evidence": [{"claimIndex": 0, "quotes": ["只有满足条件后才可能有效。"]}]}
            self.assertIn(records[0]["text"], prompt)
            self.assertNotIn("requestedQuote", prompt)
            self.assertNotIn("canBothBeTrue", schema["properties"])
            return {"verdict": "contradicted", "claimQuote": "无条件提高效率。", "evidenceQuotes": [records[0]["text"]],
                    "assumptions": [], "reason": "原文明确说不能提高效率且存在条件"}
        result = verify_node(None, model, ["无条件提高效率。"], records)
        audit = result["judgments"][0]["retrievalQuoteAudit"][0]
        self.assertTrue(audit["expanded"])
        self.assertEqual(audit["requestedQuote"], "只有满足条件后才可能有效。")
        self.assertEqual(audit["quote"], records[0]["text"])

    def test_one_node_retrieves_multiple_claims_once_and_uses_short_judgments(self):
        calls = []
        records = [{"id": "a", "text": "先确认目标。再检验结果。"}]
        def model(llm, system, prompt, schema, **kwargs):
            calls.append(schema)
            if "evidence" in schema["properties"]:
                return {"evidence": [{"claimIndex": 0, "quotes": ["先确认目标。"]}, {"claimIndex": 1, "quotes": ["再检验结果。"]}]}
            claim = schema["properties"]["claimQuote"]["enum"][0]
            return {"verdict": "supported", "claimQuote": claim, "evidenceQuotes": [claim],
                    "assumptions": [], "canBothBeTrue": True, "reason": "原文直接支持"}
        result = verify_node(None, model, ["先确认目标。", "再检验结果。"], records)
        self.assertEqual(len(calls), 3)
        self.assertTrue(all(j["sourceSpanIDs"] == ["a"] and j["verdict"] == "supported" for j in result["judgments"]))

    def test_invalid_retrieval_is_unknown_not_a_silent_partial_success(self):
        def model(*args, **kwargs):
            return {"evidence": [{"claimIndex": 0, "quotes": ["方法只在条件稳定时有效。", "方法无条件有效。"]}]}
        result = verify_node(None, model, ["方法有效"], [{"id": "a", "text": "方法只在条件稳定时有效。"}])
        self.assertEqual(result["judgments"][0]["verdict"], "unknown")
        self.assertTrue(result["quoteErrors"])

    def test_horizontal_space_fallback_preserves_raw_offsets_and_full_sentence(self):
        original = "我不赞成全部取消 ，只想研究跟 AI有关的办法。"
        requested = "只想研究跟 AI 有关的办法。"
        index = ManuscriptIndex([{"id": "a", "text": original}])
        match = index.recover(requested)
        self.assertTrue(match.whitespace_normalized)
        self.assertTrue(match.expanded)
        self.assertEqual(match.requested_quote, requested)
        self.assertEqual(index.text[match.requested_start:match.requested_end], "只想研究跟 AI有关的办法。")
        self.assertNotEqual(index.text[match.requested_start:match.requested_end], requested)
        self.assertEqual(match.text, original)
        self.assertEqual(index.locate(match.text).source_ids, ("a",))

    def test_space_fallback_cannot_change_words_numbers_punctuation_or_script(self):
        for original, requested in (("数字是1 2。", "数字是12。"),
                                    ("值是1 . 2。", "值是1.2。"),
                                    ("now here。", "nowhere。"),
                                    ("现在看AI模型。", "现在看ai模型。"),
                                    ("我還在看。", "我还在看。"),
                                    ("我，还在看。", "我还在看。"),
                                    ("中\u200b文。", "中文。"),
                                    ("不\n有效。", "不有效。")):
            with self.subTest(original=original, requested=requested):
                with self.assertRaises(QuoteError):
                    ManuscriptIndex([{"id": "a", "text": original}]).recover(requested)

    def test_space_fallback_ambiguity_and_source_gaps_are_not_rescued(self):
        index = ManuscriptIndex([{"id": "a", "text": "甲 ，乙。甲\t，乙。"}])
        with self.assertRaisesRegex(QuoteError, "exactly once"):
            index.recover("甲，乙。")
        exact_duplicate = ManuscriptIndex([{"id": "a", "text": "甲，乙。甲，乙。"}])
        with self.assertRaises(QuoteError):
            exact_duplicate.recover("甲，乙。")
        gapped = ManuscriptIndex([{"id": "a", "sequence": 1, "text": "不是 "},
                                 {"id": "b", "sequence": 3, "text": " 有效。"}])
        with self.assertRaises(QuoteError):
            gapped.recover("不是有效。")

    def test_space_fallback_passes_raw_original_not_normalized_request_to_judge(self):
        records = [{"id": "a", "text": "条件满足 ，才可以执行。"}]
        def model(llm, system, prompt, schema, **kwargs):
            if "evidence" in schema["properties"]:
                return {"evidence": [{"claimIndex": 0, "quotes": ["条件满足，才可以执行。"]}]}
            self.assertIn(records[0]["text"], prompt)
            self.assertNotIn("条件满足，才可以执行。", prompt)
            return {"verdict": "supported", "claimQuote": "执行需要条件", "evidenceQuotes": ["条件满足，才可以执行。"],
                    "assumptions": [], "reason": "原文要求条件满足"}
        result = verify_node(None, model, ["执行需要条件"], records)
        judgment = result["judgments"][0]
        self.assertEqual(judgment["verdict"], "supported")
        self.assertEqual(judgment["quotes"], [records[0]["text"]])
        self.assertTrue(judgment["quoteAudit"][0]["whitespaceNormalized"])
        self.assertTrue(judgment["retrievalQuoteAudit"][0]["whitespaceNormalized"])

    def test_space_fallback_preserves_unicode_token_boundaries(self):
        pairs = (("编号１ ２。", "编号１２。"), ("café noir。", "cafénoir。"),
                 ("А Б。", "АБ。"), ("cafe\u0301 noir。", "cafe\u0301noir。"),
                 ("数值１ ． ２。", "数值１．２。"), ("数值١ ٢。", "数值١٢。"),
                 ("分组１２ ３４。", "分组１２３４。"), ("数值1 , 234。", "数值1,234。"),
                 ("值是三 百。", "值是三百。"), ("数值1 万。", "数值1万。"),
                 ("数值三 . 五。", "数值三.五。"), ("数值三 ． 五。", "数值三．五。"),
                 ("数值三 , 五。", "数值三,五。"), ("数值− 三。", "数值−三。"),
                 ("数值＋ 三。", "数值＋三。"),
                 ("中文 ，说明。", "中文。说明。"))
        for original, requested in pairs:
            with self.subTest(original=original):
                with self.assertRaises(QuoteError):
                    ManuscriptIndex([{"id": "a", "text": original}]).recover(requested)

    def test_node_claims_share_complementary_evidence_with_one_retrieval(self):
        records = [{"id": "a", "sequence": 1, "text": "先确定目标。"},
                   {"id": "b", "sequence": 3, "text": "还需检验结果。"}]
        retrievals, judgments = [], []
        def model(llm, system, prompt, schema, **kwargs):
            if "evidence" in schema["properties"]:
                retrievals.append(prompt)
                return {"evidence": [{"claimIndex": 0, "quotes": [records[0]["text"]]},
                                     {"claimIndex": 1, "quotes": [records[1]["text"]]}]}
            judgments.append(prompt)
            self.assertTrue(all(r["text"] in prompt for r in records))
            claim = schema["properties"]["claimQuote"]["enum"][0]
            return {"verdict": "supported", "claimQuote": claim, "evidenceQuotes": [r["text"] for r in records],
                    "assumptions": [], "reason": "两条原文共同支持完整主张"}
        result = verify_node(None, model, ["先定目标再检验结果", "检验结果之前应有目标"], records)
        self.assertEqual(len(retrievals), 1)
        self.assertEqual(len(judgments), 2)
        self.assertEqual(len(result["sharedRetrievalQuoteAudit"]), 2)
        self.assertEqual(result["judgments"][0]["retrievalQuoteAudit"][0]["sourceSpanIDs"], ["a"])
        self.assertEqual(result["judgments"][1]["retrievalQuoteAudit"][0]["sourceSpanIDs"], ["b"])
        self.assertTrue(all(j["sourceSpanIDs"] == ["a", "b"] for j in result["judgments"]))

    def test_shared_evidence_never_crosses_nodes_or_fills_missing_proof(self):
        first = [{"id": "a", "text": "第一节点的独有原文。"}]
        second = [{"id": "b", "text": "这里只观察短期结果。"}]
        current = [first]
        def model(llm, system, prompt, schema, **kwargs):
            source = current[0][0]["text"]
            if "evidence" in schema["properties"]:
                return {"evidence": [{"claimIndex": 0, "quotes": [source]}]}
            if current[0] is second:
                self.assertNotIn(first[0]["text"], prompt)
            claim = schema["properties"]["claimQuote"]["enum"][0]
            return {"verdict": "unknown", "claimQuote": claim, "evidenceQuotes": [source],
                    "assumptions": [], "reason": "没有长期结果的证据"}
        verify_node(None, model, ["长期结果已得到验证"], first)
        current[0] = second
        result = verify_node(None, model, ["长期结果已得到验证"], second)
        self.assertEqual(result["judgments"][0]["verdict"], "unknown")
        self.assertEqual(result["sharedRetrievalQuoteAudit"][0]["sourceSpanIDs"], ["b"])

    def test_shared_pool_does_not_hide_one_claims_invalid_retrieval(self):
        calls = []
        def model(llm, system, prompt, schema, **kwargs):
            calls.append(schema)
            if "evidence" in schema["properties"]:
                return {"evidence": [{"claimIndex": 0, "quotes": ["编造的句子。"]},
                                     {"claimIndex": 1, "quotes": ["必须先确认条件。"]}]}
            return {"verdict": "supported", "claimQuote": "先确认条件", "evidenceQuotes": ["必须先确认条件。"],
                    "assumptions": [], "reason": "原文支持"}
        result = verify_node(None, model, ["确认条件", "先确认条件"], [{"id": "a", "text": "必须先确认条件。"}])
        self.assertEqual(result["judgments"][0]["verdict"], "unknown")
        self.assertEqual(result["judgments"][1]["verdict"], "supported")
        self.assertEqual(len(calls), 2)

    def test_shared_pool_over_budget_is_unknown_without_truncation_or_judge_call(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        records = [{"id": "a", "sequence": 1, "text": "甲" * 1800 + "。"},
                   {"id": "b", "sequence": 3, "text": "乙" * 1800 + "。"}]
        index = ManuscriptIndex(records)
        located = {i: [index.locate(record["text"])] for i, record in enumerate(records)}
        llm = SimpleNamespace(tokenize=lambda b: range(len(b) // 3), n_ctx=lambda: 4096)
        with patch("quote_evidence.retrieve_quotes", return_value=(located, [])), \
             patch("quote_evidence.judge_claim", wraps=judge_claim) as judge:
            def forbidden_model(*args, **kwargs):
                self.fail("over-budget shared source must not be truncated into a model call")
            result = verify_node(llm, forbidden_model, ["完整甲观点", "完整乙观点"], records)
        self.assertEqual(judge.call_count, 2)
        self.assertTrue(all(j["verdict"] == "unknown" and "预算" in j["reason"] for j in result["judgments"]))
        self.assertEqual([a["quote"] for a in result["sharedRetrievalQuoteAudit"]], [r["text"] for r in records])


if __name__ == "__main__":
    unittest.main()
