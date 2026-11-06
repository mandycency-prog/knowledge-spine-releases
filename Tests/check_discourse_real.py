"""Isolated real-model regression from a read-only session snapshot.

All outputs are confined to a newly created project .build subdirectory. No
database or app is written, and no model is downloaded. The model receives only
the transcript and user annotations, not an expected answer.
"""
import argparse
import copy
import hashlib
import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import local_pipeline as pipeline


def call_key(system, prompt, schema, sampling):
    # Grammar property order is part of the generation configuration. Sorting
    # schema keys would incorrectly reuse a verdict-first result for a
    # verdict-last experiment. Sampling argument order is not meaningful.
    return json.dumps([system, prompt, schema, dict(sorted(sampling.items()))], ensure_ascii=False)


def main():
    parser = argparse.ArgumentParser()
    source_group = parser.add_mutually_exclusive_group(required=True)
    source_group.add_argument("--database")
    source_group.add_argument("--input-result")
    parser.add_argument("--session-id")
    parser.add_argument("--model-path")
    parser.add_argument("--session-title")
    parser.add_argument("--annotation-manifest", help="Carry original user annotation anchors when resuming a saved result")
    parser.add_argument("--reuse-existing-proofreading", action="store_true")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--require-full-evidence-count", type=int, help="Test-only guard: every semantic audit must include this many manuscript records in one request")
    parser.add_argument("--require-quote-protocol", action="store_true", help="Require real exact-quote retrieval and judgment calls; reject the retired source-index audit")
    parser.add_argument("--reuse-model-calls", help="Reuse only identical recorded system/prompt/schema/sampling calls; legacy calls without sampling are not reused")
    parser.add_argument("--reuse-transcript-classification", action="store_true", help="Exercise the app's existing-manuscript reorganization mode without repeating background classification")
    parser.add_argument("--extend-existing-methods", action="store_true", help="Only expand a saved method map and summarize annotations; no ASR/proofreading/planning")
    args = parser.parse_args()
    if args.extend_existing_methods and not args.input_result:
        parser.error("--extend-existing-methods requires --input-result")
    out = Path(args.output_dir).resolve()
    if ROOT / ".build" not in out.parents:
        raise ValueError("Output must be a new directory below this project's .build")
    out.mkdir(parents=True, exist_ok=False)
    database_path = Path(args.database or args.input_result)
    before = database_path.read_bytes()
    db = json.loads(before)
    if args.database:
        if not args.session_id:
            raise ValueError("--database requires --session-id")
        session = next(s for s in db["sessions"] if s["id"] == args.session_id)
        model_path = db["settings"]["structureModelPath"]
    else:
        if not args.model_path:
            raise ValueError("--input-result requires --model-path")
        session = {"transcript": db["spans"], "speakers": db.get("speakers", []), "nodes": db.get("candidates", [])}
        model_path = args.model_path
    spans = session["transcript"]
    annotations = [{"id": t["id"], "kind": "thought", "text": t["text"],
                    "sourceSpanIDs": [t["anchorSpanID"]] if t.get("anchorSpanID") else [],
                    "anchorTime": t.get("anchorTime")}
                   for t in session.get("thoughts", []) if not t.get("isDeleted", False)]
    for mark in session.get("importantMarks", []):
        protected = [s for s in spans if s["id"] in mark.get("protectedSpanIDs", [])]
        anchor = next((s for s in spans if s["id"] == mark.get("anchorSpanID")), None)
        annotations.append({"id": mark["id"], "kind": "important",
                            "text": "\n".join(pipeline.effective_text(s) for s in protected),
                            "sourceSpanIDs": [s["id"] for s in protected],
                            "anchorTime": mark.get("anchorTime", anchor.get("startTime") if anchor else None)})
    if args.annotation_manifest:
        annotations = json.loads(Path(args.annotation_manifest).read_text())["annotations"]
    manifest = {"structure_model_path": model_path, "annotations": annotations,
                "reuse_existing_proofreading": args.reuse_existing_proofreading,
                "session_title": args.session_title or session.get("title", "课程知识导图"),
                "reuse_transcript_classification": args.reuse_transcript_classification}
    input_result = {"speakers": session["speakers"], "spans": spans, "candidates": [], "warnings": db.get("warnings", []) if args.input_result else []}
    pipeline.write_result(out / "manifest.json", manifest)
    pipeline.write_result(out / "input.json", input_result)
    if not args.run:
        print(out)
        return
    pipeline.write_result(out / "implementation.json", {
        "files": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in (ROOT / "Backend/local_pipeline.py", ROOT / "Backend/quote_evidence.py", ROOT / "Backend/source_bound_map.py", ROOT / "Backend/stage_synthesis.py", ROOT / "Backend/branch_expansion.py", ROOT / "Backend/transcript_proofreader.py", ROOT / "Backend/punctuation_formatter.py", Path(__file__).resolve())
                  if path.exists()},
        "inputSHA256": hashlib.sha256(before).hexdigest(),
        "requireQuoteProtocol": args.require_quote_protocol,
        "reuseModelCalls": args.reuse_model_calls,
        "cacheSHA256": hashlib.sha256(Path(args.reuse_model_calls).read_bytes()).hexdigest() if args.reuse_model_calls else None,
    })
    real_completion = pipeline.structured_completion
    calls = []
    cached = {}
    if args.reuse_model_calls:
        for prior in json.loads(Path(args.reuse_model_calls).read_text()):
            if "result" in prior and "error" not in prior and isinstance(prior.get("sampling"), dict):
                cached[call_key(prior["system"], prior["prompt"], prior["schema"], prior["sampling"])] = prior["result"]
    def traced(llm, system, prompt, schema, **sampling):
        start = time.monotonic()
        record = {"system": system, "prompt": prompt, "schema": schema, "sampling": sampling}
        try:
            if args.require_quote_protocol and "supportedClaims" in schema.get("properties", {}):
                raise ValueError("Retired source-index audit was invoked instead of exact-quote protocol")
            if args.require_full_evidence_count is not None and "supportedClaims" in schema.get("properties", {}):
                evidence = json.loads(prompt.split("待核对：", 1)[1])["evidence"]
                if len(evidence) != args.require_full_evidence_count:
                    raise ValueError("Isolated test requires all manuscript evidence in one audit request")
            key = call_key(system, prompt, schema, sampling)
            if key in cached:
                result = copy.deepcopy(cached[key])
                record["reusedFrom"] = args.reuse_model_calls
            else:
                result = real_completion(llm, system, prompt, schema, **sampling)
            record["result"] = result
            return result
        except Exception as error:
            record["error"] = repr(error)
            frame = error.__traceback__
            while frame is not None:
                if frame.tb_frame.f_code.co_name == "structured_completion":
                    content = frame.tb_frame.f_locals.get("content")
                    if isinstance(content, str):
                        record["invalidCompletion"] = content
                frame = frame.tb_next
            raise
        finally:
            record["seconds"] = time.monotonic() - start
            calls.append(record)
            pipeline.write_result(out / "model-calls.json", calls)
    pipeline.structured_completion = traced
    summaries = []
    start = time.monotonic()
    try:
        if args.extend_existing_methods:
            from source_bound_map import expand_method_branches
            prior_nodes = copy.deepcopy(db.get("candidates", []))
            if not prior_nodes:
                raise ValueError("No existing method map")
            llm = pipeline.load_structure_model(manifest)
            input_result["candidates"], warnings = expand_method_branches(llm, prior_nodes, spans, traced, pipeline.emit_progress)
            methods = [n for n in prior_nodes if n.get("parentID") == prior_nodes[0]["nodeID"]
                       and n.get("kind") == "主线" and n.get("sourceBoundStatus") == "summarized"]
            recovered = {i for i, method in enumerate(methods, 1)
                         if any(n.get("parentID") == method["nodeID"] for n in input_result["candidates"])}
            # Retire only a prior branch warning whose children now actually exist.
            input_result["warnings"] = [warning for warning in input_result["warnings"]
                if not ((match := re.match(r"第(\d+)条方法的子分支未完成", warning))
                        and int(match.group(1)) in recovered)]
            input_result["warnings"].extend(warnings)
            pipeline.emit_progress("正在概括重点的整体意思与要点")
            summaries.extend(pipeline.summarize_annotations(llm, annotations, spans))
        else:
            input_result["candidates"] = pipeline.structure(manifest, spans, out / "provisional.json", annotation_summaries=summaries,
                                                           processing_warnings=input_result["warnings"])
        if args.require_quote_protocol:
            retrievals = [call for call in calls if "originalSentences" in call["prompt"]
                          and "evidence" in call["schema"].get("properties", {})]
            judgments = [call for call in calls if "claimQuote" in call["schema"].get("properties", {})]
            if (not any("reusedFrom" not in call for call in retrievals)
                    or not any("reusedFrom" not in call for call in judgments)):
                raise ValueError("Real exact-quote retrieval and judgment were not exercised")
    except Exception as error:
        pipeline.write_result(out / "result-checkpoint.json", input_result)
        pipeline.write_result(out / "report.json", {
            "status": "pipeline_failed", "error": repr(error), "seconds": time.monotonic() - start,
            "modelCalls": len(calls), "newModelCalls": sum("reusedFrom" not in call for call in calls),
            "spanCount": len(spans), "databaseSHA256Before": hashlib.sha256(before).hexdigest(),
            "databaseSHA256After": hashlib.sha256(database_path.read_bytes()).hexdigest(),
            "appliedToDatabase": False,
        })
        raise
    input_result["annotationSummaries"] = summaries
    pipeline.write_result(out / "result.json", input_result)
    known = {s["id"] for s in spans if not s.get("isBackgroundAudio", False)}
    nodes = input_result["candidates"]
    invalid = [s for n in nodes for s in n["sourceSpanIDs"] if s not in known]
    report = {"status": "pipeline_complete_pending_independent_review", "seconds": time.monotonic() - start, "oldNodeCount": len(session.get("nodes", [])),
              "newNodeCount": len(nodes), "spanCount": len(spans), "invalidSources": invalid,
              "annotationSummaryCount": len(summaries), "modelCalls": len(calls),
              "databaseSHA256Before": hashlib.sha256(before).hexdigest(),
              "databaseSHA256After": hashlib.sha256(database_path.read_bytes()).hexdigest(),
              "titles": [n["summary"] for n in nodes]}
    pipeline.write_result(out / "report.json", report)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    roots = {n["nodeID"] for n in nodes if n.get("navigationRoot") is True}
    methods = [n for n in nodes if n.get("parentID") in roots]
    if invalid or len(roots) != 1 or not 1 <= len(methods) <= 7:
        raise RuntimeError("Source or compactness regression")


if __name__ == "__main__":
    main()
