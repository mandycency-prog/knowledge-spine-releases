"""Read-only small-context diagnostic for the local reader; never edits App data."""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import local_pipeline as pipeline

parser = argparse.ArgumentParser()
parser.add_argument("--manifest", required=True)
parser.add_argument("--input", required=True)
parser.add_argument("--start", type=int, required=True)
parser.add_argument("--end", type=int, required=True)
parser.add_argument("--question", required=True)
parser.add_argument("--output", required=True)
parser.add_argument("--official-sampling", action="store_true")
parser.add_argument("--nonthinking", action="store_true")
args = parser.parse_args()
output = Path(args.output).resolve()
if ROOT / ".build" not in output.parents or output.exists():
    raise ValueError("Use a new output in .build")
source = json.loads(Path(args.input).read_bytes())
spans = sorted(source["spans"], key=lambda s: s["sequence"])[args.start:args.end]
manifest = json.loads(Path(args.manifest).read_bytes())
manifest["focus_question"] = args.question
model = pipeline.load_structure_model(manifest)
schema = {"type": "object", "properties": {"explanation": {"type": "string"}},
          "required": ["explanation"], "additionalProperties": False}
prompt = ("只回答用户的问题。先区分原文中的不同对象、办理时间、统计期间、否定和例外，"
          "后文明确补充的条件不能遗漏；不补常识。回答清楚具体，不重复无关话题。材料：\n"
          + "\n".join(s.get("correctedText") or s["originalText"] for s in spans)
          + "\n用户的问题：" + args.question)
sampling = (dict(temperature=1.0, top_p=0.95, top_k=20, min_p=0.0,
                 presence_penalty=1.5, repeat_penalty=1.0) if args.official_sampling else dict(temperature=0.1))
if args.nonthinking and args.official_sampling:
    sampling.update(temperature=0.7, top_p=0.8)
answer = pipeline.structured_completion(model, "你是根据原文回答问题的阅读助手。", prompt, schema,
                                       reasoned_json=not args.nonthinking, max_tokens=1800, **sampling,
                                       progress_callback=pipeline.emit_progress)
pipeline.write_result(output, answer)
print(json.dumps(answer, ensure_ascii=False), flush=True)
model.close()
