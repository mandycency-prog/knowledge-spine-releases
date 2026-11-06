"""Development replay: vary only JSON field order, not prompts or retrieval."""
import argparse
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import resource
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import local_pipeline as pipeline
import quote_evidence as evidence


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model-path", required=True)
    args = parser.parse_args()
    source, out = Path(args.baseline).resolve(), Path(args.output_dir).resolve()
    if ROOT / ".build" not in source.parents or ROOT / ".build" not in out.parents:
        raise ValueError("Baseline and fresh output must be isolated .build children")
    out.mkdir(parents=True, exist_ok=False)
    baseline = json.loads(source.read_text())
    judgments = [c for c in baseline if "verdict" in c["schema"]["properties"]]
    fixture = ROOT / "Tests/Fixtures/topic_semantic_cases.json"
    inputs = {c["id"]: c["input"] for c in json.loads(fixture.read_text())["cases"]}
    def write(name, value):
        (out / name).write_text(json.dumps(value, ensure_ascii=False, indent=2))
    files = [source, fixture, Path(__file__), ROOT / "Backend/quote_evidence.py", ROOT / "Backend/local_pipeline.py"]
    write("implementation.json", {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    start = time.monotonic()
    llm = pipeline.load_structure_model({"structure_model_path": args.model_path})
    calls, results = [], []
    for saved in judgments:
        supplied = inputs[saved["caseID"]]
        original_input = json.loads(saved["prompt"].split("输入：", 1)[1])
        index = evidence.ManuscriptIndex(supplied["records"])
        matches = [replace(index.recover(text), context=text) for text in original_input["sourceContexts"]]
        llm.reset()
        def complete(model, system, prompt, schema, **sampling):
            sampling["seed"] = 20260911
            if system != saved["system"] or prompt != saved["prompt"] or schema != saved["schema"] or sampling != saved["sampling"]:
                raise ValueError("Replay changed something other than grammar property order")
            changed = dict(schema, properties={key: schema["properties"][key] for key in
                           ("claimQuote", "evidenceQuotes", "assumptions", "reason", "verdict")})
            call = {"caseID": saved["caseID"], "system": system, "prompt": prompt,
                    "originalSchema": schema, "schema": changed, "sampling": sampling}
            began = time.monotonic()
            original = model.create_completion
            def capture(**kwargs):
                response = original(**kwargs)
                call["rawCompletion"] = response
                call["renderedPrompt"] = kwargs.get("prompt")
                return response
            model.create_completion = capture
            try:
                value = pipeline.structured_completion(model, system, prompt, changed, **sampling)
                call["result"] = value
                return value
            except BaseException as error:
                call["error"] = repr(error)
                raise
            finally:
                model.create_completion = original
                call["seconds"] = time.monotonic() - began
                calls.append(call)
                write("calls.json", calls)
        began = time.monotonic()
        try:
            result = evidence.judge_claim(llm, complete, original_input["claimQuote"], matches, index,
                                          semantic_role="topic", scope_notes=original_input["scopeNotes"])
            row = {"judgment": result, "protocolValid": "quotes" in result}
        except Exception as error:
            row = {"error": repr(error), "protocolValid": False}
        row.update(caseID=saved["caseID"], baselineVerdict=saved["result"]["verdict"], seconds=time.monotonic() - began)
        results.append(row)
        write("results.json", results)
        print(json.dumps(row, ensure_ascii=False), flush=True)
    write("report.json", {"comparisonCount": len(results), "modelCalls": len(calls),
          "seconds": time.monotonic() - start,
          "maximumProcessRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
          "notCompared": [identifier for identifier in inputs if identifier not in {r["caseID"] for r in results}],
          "limitations": "Development replay, not independent acceptance. Retrieval is frozen; no expected labels prompted, no retry. Only property order changed; relevance case with no prior judgment is untested."})


if __name__ == "__main__":
    main()
