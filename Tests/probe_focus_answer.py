"""Isolated source-only probe; never writes the application database."""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import local_pipeline as pipeline
import focused_study as study

parser = argparse.ArgumentParser()
parser.add_argument("--manifest", required=True)
parser.add_argument("--trace", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--audit-draft", action="store_true")
parser.add_argument("--condition-cards", action="store_true")
parser.add_argument("--input-result", help="Rebuild continuous original passages with four-chunk context from the frozen source")
args = parser.parse_args()
out = Path(args.output).resolve()
if ROOT / ".build" not in out.parents or out.exists():
    raise ValueError("Use a new isolated .build output")
data = json.loads(Path(args.trace).read_bytes())
source = json.loads(data["prompt"].split("输入：", 1)[1])
if args.input_result:
    import re
    raw = sorted(json.loads(Path(args.input_result).read_bytes())["spans"], key=lambda s: s["sequence"])
    records = study._records(raw)
    keys = {int(k) for k in re.findall(r"\[(\d+)\]", source["transcript"])}
    expanded = {n for k in keys for n in range(max(0, k - 2), min(len(records), k + 3))
                if records[n].get("origin") == records[k].get("origin")}
    source["transcript"] = study._passages([records[k] for k in sorted(expanded)])
prompt = ("根据原文回答问题，概括清楚即可，不必抄全文。只使用原文支持的事实，"
          "区分不同事项、阶段的条件，保留否定与例外。口语里的自我纠正以完整后文为准。"
          "输出JSON：explanation为答案，sourceKeys为依据的原文编号。\n问题：" +
          source["subquestion"] + "\n原文：\n" + source["transcript"])
model = pipeline.load_structure_model(json.loads(Path(args.manifest).read_bytes()))
try:
    schema = study._answer_schema()
    if args.condition_cards:
        schema = {"type": "object", "properties": {
            "overview": {"type": "string"},
            "cards": {"type": "array", "items": {"type": "object", "properties": {
                "sourceKeys": {"type": "array", "items": {"type": "integer"}}},
                "required": ["sourceKeys"], "additionalProperties": False}}},
            "required": ["overview", "cards"], "additionalProperties": False}
        prompt = ("围绕问题整理原文中的关键条件。overview只概括涉及哪些事项、它们的区别，"
                  "不改写数字、期限、阶段或资格条件。"
                  "cards选择1至4条能够直接讲清条件的最短完整原话，用sourceKeys列原文编号，程序会原样展示。"
                  "口语前句不完整、后句纠正或明确补充时，优先选择明确完整的后句；不要重复泛称和不完整前句。"
                  "只选直接回答问题的原文，不能把其他事项的日期当成所问事项的日期。"
                  "输出JSON，不输出其他内容。\n问题：" + source["subquestion"] +
                  "\n原文：\n" + source["transcript"])
    if args.audit_draft:
        schema = {"type": "object", "properties": {
            "errors": {"type": "string"}, **schema["properties"]},
            "required": ["errors", "explanation", "sourceKeys"], "additionalProperties": False}
        prompt = ("审查下面的错误草稿。先在errors里逐条指出它与原文具体哪里不同；"
                  "尤其检查它有没有漏掉后文例外、把不同事项和时间混在一起。"
                  "然后在explanation里重新写正确的回答，sourceKeys列出支持正确答案的原文编号。"
                  "不能只复制草稿。\n问题：" + source["subquestion"] +
                  "\n原文：\n" + source["transcript"] +
                  "\n待审查草稿（可能错误，不是证据）：" + data["answer"]["explanation"])
    answer = pipeline.structured_completion(model, study.SYSTEM, prompt, schema,
        max_tokens=1200, temperature=0.7, top_p=0.8, top_k=20, min_p=0,
        presence_penalty=1.5, repeat_penalty=1, progress_callback=pipeline.emit_progress)
    pipeline.write_result(out, {"prompt": prompt, "answer": answer})
finally:
    model.close()
