"""One fixed-seed diagnostic; full source supplied, expected answers never prompted."""
import argparse
from dataclasses import replace
import hashlib
import inspect
import json
from pathlib import Path
import resource
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import local_pipeline as pipeline
import quote_evidence as evidence
from experimental_reasoning_completion import reasoning_completion


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model-path", required=True)
    args = parser.parse_args()
    out = Path(args.output_dir).resolve()
    if ROOT / ".build" not in out.parents:
        raise ValueError("Fresh isolated .build child required")
    out.mkdir(parents=True, exist_ok=False)
    fixture_path = ROOT / "Tests/Fixtures/reasoning_mode_cases.json"
    # Score only after all calls. Only this input projection reaches the driver.
    cases = [{"id": c["id"], "input": c["input"]}
             for c in json.loads(fixture_path.read_text())["cases"]]
    def write(name, value):
        (out / name).write_text(json.dumps(value, ensure_ascii=False, indent=2))
    files = [Path(__file__), fixture_path, ROOT / "Backend/quote_evidence.py",
             ROOT / "Backend/local_pipeline.py", ROOT / "Tests/experimental_reasoning_completion.py"]
    write("implementation.json", {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    started = time.monotonic()
    llm = pipeline.load_structure_model({"structure_model_path": args.model_path})
    defaults = {k: v.default for k, v in inspect.signature(llm.create_completion).parameters.items()
                if k in ("temperature", "top_p", "top_k", "min_p", "presence_penalty", "repeat_penalty")}
    calls, results = [], []
    for case in cases:
        supplied = case["input"]
        records = [{"id": f"{case['id']}-source-{i}", "sequence": i,
                    "text": text} for i, text in enumerate(supplied["sourceContexts"])]
        index = evidence.ManuscriptIndex(records)
        # Full independent contexts, without retrieval or neighbor expansion.
        matches = [replace(index.locate(r["text"]), context=r["text"]) for r in records]
        for mode in ("direct", "thinking"):
            llm.reset()
            def complete(model, system, prompt, schema, **sampling):
                call = {"caseID": case["id"], "mode": mode, "system": system,
                        "prompt": prompt, "schema": schema}
                began = time.monotonic()
                try:
                    if mode == "direct":
                        sampling["seed"] = 20260911
                        call["sampling"] = dict(defaults, **sampling)
                        original_completion = model.create_completion
                        def captured_completion(**kwargs):
                            response = original_completion(**kwargs)
                            call["rawCompletion"] = response
                            call["renderedPrompt"] = kwargs.get("prompt")
                            return response
                        model.create_completion = captured_completion
                        try:
                            value = pipeline.structured_completion(model, system, prompt, schema, **sampling)
                        finally:
                            model.create_completion = original_completion
                        call.update(status="completed", value=value)
                    else:
                        diagnostic = reasoning_completion(model, system, prompt, schema, seed=20260911)
                        call["diagnostic"] = diagnostic
                        if diagnostic["status"] != "completed":
                            raise RuntimeError(diagnostic["status"])
                        value = diagnostic["value"]
                    return value
                except Exception as error:
                    call["error"] = repr(error)
                    raise
                finally:
                    call["seconds"] = time.monotonic() - began
                    calls.append(call)
                    write("calls.json", calls)
            began = time.monotonic()
            try:
                judgment = evidence.judge_claim(llm, complete, supplied["claimQuote"], matches, index)
                result = {"judgment": judgment}
            except Exception as error:
                result = {"error": repr(error)}
            result.update(caseID=case["id"], mode=mode, seconds=time.monotonic() - began)
            results.append(result)
            write("results.json", results)
            print(json.dumps(result, ensure_ascii=False), flush=True)
    expected = json.loads(fixture_path.read_text())["expected_by_id"]
    for result in results:
        result["expectedVerdict"] = expected[result["caseID"]]["verdict"]
        result["verdictCorrect"] = result.get("judgment", {}).get("verdict") == result["expectedVerdict"]
    write("scored-results.json", results)
    write("report.json", {"modelPath": args.model_path, "caseCount": len(cases),
          "seconds": time.monotonic() - started,
          "maximumProcessRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
          "scores": {mode: sum(r["verdictCorrect"] for r in results if r["mode"] == mode)
                     for mode in ("direct", "thinking")},
          "limitations": "Four short independent diagnostics; verdict scores are not evidence sufficiency or product acceptance. Thinking and sampling jointly vary; not an isolated causal test of thinking. Fixed seed, no retry or expected-answer feedback."})


if __name__ == "__main__":
    main()
