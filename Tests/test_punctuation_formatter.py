import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import punctuation_formatter as p


def span(i, text, **extra):
    return dict(id=f"source-{i}", sequence=i, originalText=text, speakerID="speaker", **extra)


class PunctuationFormatterTests(unittest.TestCase):
    def test_natural_chinese_punctuation_is_not_a_word_edit(self):
        raw = "好,接下来先确认条件是否满足如果满足就操作"
        formatted, _ = p._apply([span(0, raw)], {"text": "好，接下来先确认：条件是否满足？如果满足，就操作。"})
        self.assertEqual(formatted, ["好,接下来先确认：条件是否满足？如果满足，就操作。"])
        self.assertTrue(p.insertion_only(raw, formatted[0]))
        repeated = "开始的时候是152吧 152金然后继续确认"
        formatted, _ = p._apply([span(0, repeated)], {"text": "开始的时候是 152 吧，152 金，然后继续确认。"})
        self.assertTrue(p.insertion_only(repeated, formatted[0]))

    def test_continuous_input_maps_back_and_reuses_without_word_changes(self):
        spans = [span(0, "如果条件满足"), span(1, "就开始操作然后核对结果")]
        before = copy.deepcopy(spans); calls = []
        def complete(llm, system, prompt, schema, **kw):
            calls.append(json.loads(prompt.split("连续原稿：")[1]))
            return {"text": "如果条件满足，就开始操作，然后核对结果。"}
        self.assertEqual(p.punctuate_transcript(None, spans, complete), [])
        self.assertEqual(spans[0]["proofreadPunctuatedText"], "如果条件满足，")
        self.assertEqual(spans[1]["proofreadPunctuatedText"], "就开始操作，然后核对结果。")
        self.assertEqual(calls, ["如果条件满足就开始操作然后核对结果"])
        for old, new in zip(before, spans):
            self.assertEqual({k: new[k] for k in old}, old)
            self.assertNotIn("proofreadingVersion", new)
        self.assertEqual(p.punctuate_transcript(None, spans, lambda *a, **k: self.fail("重复断句")), [])

    def test_reading_basis_and_uncertainties_survive(self):
        s = span(0, "这项任物完成后复核", proofreadText="这项任务完成后复核", proofreadBasis="这项任物完成后复核",
                 proofreadUncertainties=["专名待确认"], proofreadingVersion="context-v1")
        old = copy.deepcopy(s)
        p.punctuate_transcript(None, [s], lambda *a, **k: {"text": "这项任务完成后，复核。"})
        self.assertEqual(s["proofreadPunctuatedText"], "这项任务完成后，复核。")
        self.assertEqual({k: s[k] for k in old}, old)

    def test_small_word_change_ignored_other_punctuation_taken(self):
        raw = "首先核对材料中的关键信息然后检查每个步骤的执行顺序接下来请记录观察到的现象再核查现场条件是否符合要求最后保存结果以便之后继续比较分析当前材料仍然存在不确定的地方需要由相关人员结合实际情况逐项核对不能仅凭一次观察就下结论"
        proposed = raw.replace("关键信息", "关健信息").replace("执行顺序", "执行顺序，").replace("之后继续比较分析", "之后继续比较分析，") + "。"
        s = span(0, raw)
        self.assertTrue(p.punctuate_transcript(None, [s], lambda *a, **k: {"text": proposed}))
        out = s["proofreadPunctuatedText"]
        self.assertIn("关键信息", out)
        self.assertNotIn("关健信息", out)
        self.assertIn("执行顺序，", out)
        self.assertIn("之后继续比较分析，", out)
        self.assertTrue(p.insertion_only(raw, out))
        self.assertEqual("".join(c for c in out if c not in p.MARKS), raw)

    def test_rewrite_or_bad_response_rejects_entire_batch_no_retry(self):
        for value in [{"text": "无需核对，立即执行。"}, {"text": ""}, {"text": []}, {"text": "原词", "extra": 1},
                      {"insertions": []}, '{"text":']:
            with self.subTest(value=value):
                s = span(0, "现在先检查原始材料然后再讨论下一步行动"); calls = []
                def complete(*a, **kw):
                    calls.append(1); return value
                self.assertTrue(p.punctuate_transcript(None, [s], complete))
                self.assertEqual(calls, [1])
                self.assertEqual(s["proofreadPunctuatedText"], s["originalText"])

    def test_whitespace_edits_do_not_reject_other_punctuation_or_change_raw_spaces(self):
        raw = "先 核 对 材 料然后操作最后保存结果"
        s = span(0, raw)
        warnings = p.punctuate_transcript(None, [s], lambda *a, **kw: {"text": "先核对材料然后操作，最后保存结果。"})
        self.assertTrue(warnings)
        self.assertEqual(s["proofreadPunctuatedText"], "先 核 对 材 料然后操作，最后保存结果。")
        self.assertEqual(s["originalText"], raw)

    def test_manual_user_background_are_untouched(self):
        spans = [span(0, "用户输入", origin={"authoredByUser": True}), span(1, "识别", correctedText="我修正的稿"),
                 span(2, "音乐", isBackgroundAudio=True)]
        old = copy.deepcopy(spans)
        self.assertEqual(p.punctuate_transcript(None, spans, lambda *a, **k: self.fail("不能调用")), [])
        self.assertEqual(spans, old)

    def test_unicode_existing_marks_and_decimal_preserved(self):
        source = [span(0, "甲😀"), span(1, "乙。丙")]
        self.assertEqual(p._apply(source, {"text": "甲😀，乙。丙。"})[0], ["甲😀，", "乙。丙。"])
        out, ignored = p._apply([span(0, "需要1"), span(1, "2.5分钟")], {"text": "需要1，2.5分钟。"})
        self.assertTrue(ignored)
        self.assertEqual(out, ["需要1", "2.5分钟。"])
        out, ignored = p._apply([span(0, "先核对，后执行。")], {"text": "先核对后执行。"})
        self.assertTrue(ignored)
        self.assertEqual(out, ["先核对，后执行。"])
        self.assertFalse(p.insertion_only("12.5", "12，5"))

    def test_failure_keeps_notes_and_continues_next_course(self):
        source = [span(0, "甲课程", proofreadText="甲课程", proofreadBasis="甲课程", proofreadUncertainties=["原疑点"]),
                  span(1, "乙课程", origin={"sessionID": "other"})]; calls = []
        def complete(*a, **kw):
            calls.append(1)
            if len(calls) == 1: raise RuntimeError("fail")
            return {"text": "乙课程。"}
        self.assertEqual(len(p.punctuate_transcript(None, source, complete)), 1)
        self.assertEqual(source[0]["proofreadUncertainties"], ["原疑点"])
        self.assertEqual(source[1]["proofreadPunctuatedText"], "乙课程。")

    def test_stale_basis_uses_original_without_success_version(self):
        s = span(0, "新识别", proofreadText="旧文字", proofreadBasis="旧识别", proofreadingVersion="old")
        p.punctuate_transcript(None, [s], lambda *a, **kw: {"text": "新识别。"})
        self.assertEqual(s["proofreadText"], "新识别")
        self.assertEqual(s["proofreadBasis"], "新识别")
        self.assertNotIn("proofreadingVersion", s)

    def test_budget_and_sequence_breaks_no_truncation(self):
        source = [span(0, "甲" * 500), span(1, "乙" * 500), span(3, "丙")]; calls = []
        def complete(llm, system, prompt, schema, **kw):
            text = json.loads(prompt.split("连续原稿：")[1]); calls.append(text)
            self.assertLessEqual(len(text), p.MAX_CHARS)
            self.assertLessEqual(kw["max_tokens"], 3072)
            return {"text": text}
        self.assertEqual(p.punctuate_transcript(None, source, complete), [])
        self.assertEqual(len(calls), 3)
        huge = span(0, "甲" * (p.MAX_CHARS + 1))
        self.assertTrue(p.punctuate_transcript(None, [huge], lambda *a, **k: self.fail("超预算调用")))
        self.assertEqual(huge["proofreadPunctuatedText"], huge["originalText"])

    def test_duplicate_ids_reject_and_bad_cache_not_reused(self):
        source = [span(0, "甲"), span(0, "乙")]; old = copy.deepcopy(source)
        self.assertTrue(p.punctuate_transcript(None, source, lambda *a, **k: self.fail("无效来源")))
        self.assertEqual(source, old)
        s = span(0, "原文", proofreadPunctuatedText="被换字")
        p.punctuate_transcript(None, [s], lambda *a, **kw: {"text": "原文。"})
        self.assertEqual(s["proofreadPunctuatedText"], "原文。")


if __name__ == "__main__":
    unittest.main()
