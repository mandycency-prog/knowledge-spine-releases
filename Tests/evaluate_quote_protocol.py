"""Small isolated semantic evaluation. Expected labels NEVER enter prompts."""
import argparse
import json
from pathlib import Path
import resource
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import local_pipeline as pipeline
import quote_evidence


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=["development", "holdout"], default="development")
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    out = Path(args.output_dir).resolve()
    if ROOT / ".build" not in out.parents:
        raise ValueError("Only fresh .build evaluation directories are allowed")
    out.mkdir(parents=True, exist_ok=False)
    fixture = json.loads((ROOT / "Tests/Fixtures/semantic_acceptance_cases.json").read_text())
    cases = [c for c in fixture["cases"] if c["split"] == args.split]
    calls, results = [], []
    started = time.monotonic()
    llm = pipeline.load_structure_model({"structure_model_path": args.model_path})
    def write(name, value):
        (out / name).write_text(json.dumps(value, ensure_ascii=False, indent=2))
    current = ""
    def complete(llm, system, prompt, schema, **sampling):
        start = time.monotonic()
        call = {"caseID": current, "system": system, "prompt": prompt, "schema": schema}
        try:
            result = pipeline.structured_completion(llm, system, prompt, schema, **sampling)
            call["result"] = result
            return result
        except Exception as error:
            call["error"] = repr(error)
            raise
        finally:
            call["seconds"] = time.monotonic() - start
            calls.append(call)
            write("calls.json", calls)
    for case in cases:
        current = case["id"]
        supplied = case["input"]
        # Deliberately do not pass proposed_evidence or expected labels to LLM.
        try:
            result = quote_evidence.verify_node(llm, complete, [supplied["claim"]], supplied["spans"])
            judgment = result["judgments"][0]
        except Exception as error:
            result = {"error": repr(error)}
            judgment = {"verdict": "unknown", "reason": repr(error), "quotes": []}
        expected = case["expected"]["semantic_verdict"]
        expected = "unknown" if expected == "insufficient_evidence" else expected
        index = quote_evidence.ManuscriptIndex(supplied["spans"])
        resolved = [index.locate(q) for q in judgment.get("quotes", [])]
        alternatives = case["expected"].get("sufficient_evidence_alternatives", [])
        if expected == "contradicted":
            alternatives = [case["expected"].get("contradiction_evidence", [])]
        sufficient = any(all(any(e["source_id"] in m.source_ids and e["quote"] in m.text for m in resolved)
                             for e in alternative) for alternative in alternatives) if expected != "unknown" else None
        results.append({"caseID": current, "category": case["category"], "expected": expected,
                        "actual": judgment["verdict"], "semanticCorrect": judgment["verdict"] == expected,
                        "expectedEvidenceLocated": sufficient, "result": result})
        write("results.json", results)
    positives = [r for r in results if r["expected"] == "supported"]
    negatives = [r for r in results if r["expected"] != "supported"]
    report = {"split": args.split, "caseCount": len(results), "modelCalls": len(calls),
              "correctSupportRate": sum(r["actual"] == "supported" for r in positives) / len(positives),
              "correctRejectionRate": sum(r["actual"] != "supported" for r in negatives) / len(negatives),
              "threeWayAccuracy": sum(r["semanticCorrect"] for r in results) / len(results),
              "unknownRate": sum(r["actual"] == "unknown" for r in results) / len(results),
              "wrongSupportCount": sum(r["actual"] == "supported" and r["expected"] != "supported" for r in results),
              "semanticAndEvidenceCorrectCount": sum(r["semanticCorrect"] and r["expectedEvidenceLocated"] is not False for r in results),
              "seconds": time.monotonic() - started, "maximumProcessRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
              "limitations": "Synthetic small-set evaluation, not whole-course or general safety proof. Exact location alone is not semantic correctness. No formal data writes/downloads."}
    write("report.json", report)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
