"""Isolated independent topic evaluation; no expected answers reach the model."""
import argparse
import hashlib
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
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    out = Path(args.output_dir).resolve()
    if ROOT / ".build" not in out.parents:
        raise ValueError("Only a fresh isolated .build child is allowed")
    out.mkdir(parents=True, exist_ok=False)
    fixture_path = ROOT / "Tests/Fixtures/topic_semantic_cases.json"
    cases = [{"id": c["id"], "input": c["input"]}
             for c in json.loads(fixture_path.read_text())["cases"]]
    def write(name, value):
        (out / name).write_text(json.dumps(value, ensure_ascii=False, indent=2))
    files = [Path(__file__), fixture_path, ROOT / "Backend/quote_evidence.py", ROOT / "Backend/local_pipeline.py"]
    write("implementation.json", {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    started = time.monotonic()
    llm = pipeline.load_structure_model({"structure_model_path": args.model_path})
    calls, results = [], []
    for case in cases:
        supplied = case["input"]
        llm.reset()
        def complete(model, system, prompt, schema, **sampling):
            sampling["seed"] = 20260911
            call = {"caseID": case["id"], "system": system, "prompt": prompt,
                    "schema": schema, "sampling": sampling, "rawCompletions": []}
            began = time.monotonic()
            original = model.create_completion
            def capture(**kwargs):
                value = original(**kwargs)
                call["rawCompletions"].append({"prompt": kwargs.get("prompt"), "response": value})
                return value
            model.create_completion = capture
            try:
                result = pipeline.structured_completion(model, system, prompt, schema, **sampling)
                call["result"] = result
                return result
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
            scope = [{"summary": stage["summary"], "argumentSummary": stage.get("argumentSummary", "")}
                     for stage in supplied["stages"]]
            value = quote_evidence.verify_topic(llm, complete, supplied["topic"], supplied["records"], scope)
            # Internal QuoteError and budget failures become unknown without
            # the normal quote fields. They are protocol failures, not evidence
            # that the model detected a semantically wrong topic.
            protocol_valid = not value["quoteErrors"] and bool(value["judgments"]) and all(
                "quotes" in j and j.get("verdict") in ("supported", "contradicted", "unknown")
                for j in value["judgments"])
            raw_verdicts = [call["result"]["verdict"] for call in calls
                            if call["caseID"] == case["id"] and "verdict" in call.get("result", {})]
            protocol_valid = protocol_valid and bool(raw_verdicts)
            accepted = protocol_valid and all(
                j["verdict"] == "supported" for j in value["judgments"])
            result = {"result": value, "accepted": accepted, "protocolValid": protocol_valid,
                      "rawVerdicts": raw_verdicts,
                      "postValidationVerdicts": [j["verdict"] for j in value["judgments"]]}
        except Exception as error:
            result = {"error": repr(error), "accepted": False, "protocolValid": False,
                      "rawVerdicts": [], "postValidationVerdicts": []}
        result.update(caseID=case["id"], seconds=time.monotonic() - began)
        results.append(result)
        write("results.json", results)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    # Scoring is deliberately after every model call; there are no retries.
    expected = json.loads(fixture_path.read_text())["expected_by_id"]
    for result in results:
        result["expectedAccepted"] = expected[result["caseID"]]["acceptable"]
        result["decisionCorrect"] = (result["accepted"] == result["expectedAccepted"]
                                     if result["protocolValid"] else None)
    write("scored-results.json", results)
    write("report.json", {"caseCount": len(results), "modelCalls": len(calls),
          "completedJudgment": sum(r["protocolValid"] for r in results),
          "validDecisionCorrect": sum(r["decisionCorrect"] is True for r in results),
          "errored": sum(not r["protocolValid"] for r in results),
          "unknown": sum(r["protocolValid"] and "unknown" in r["postValidationVerdicts"] for r in results),
          "contradicted": sum(r["protocolValid"] and "contradicted" in r["postValidationVerdicts"] for r in results),
          "falselyAccepted": sum(r["accepted"] and not r["expectedAccepted"] for r in results),
          "seconds": time.monotonic() - started,
          "maximumProcessRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
          "limitations": "Four synthetic independent diagnostics, not whole-course acceptance. Final evidence sufficiency requires separate review; unknown rejection alone is not proof of semantic detection. No expected-answer feedback, downloads or formal-data writes."})


if __name__ == "__main__":
    main()
