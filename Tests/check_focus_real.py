"""Run the production focused reader against a read-only snapshot, with call traces."""
import argparse
import json
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import local_pipeline as pipeline
import focused_study


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--input-result", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--transfer-check", action="store_true")
    parser.add_argument("--transfer-only", action="store_true")
    parser.add_argument("--replay-drafts", help="Isolated editor probe only: reuse previous planner/answer traces, never a release acceptance run")
    args = parser.parse_args()
    out = Path(args.output_dir).resolve()
    if ROOT / ".build" not in out.parents:
        raise ValueError("Only a new project .build directory is permitted")
    out.mkdir(parents=True, exist_ok=False)
    source = Path(args.input_result)
    before = source.read_bytes()
    result = json.loads(before)
    manifest = json.loads(Path(args.manifest).read_bytes())
    if args.transfer_only:
        texts = ["今天主要介绍相机的光圈、快门和人像构图。",
                 "另外讲一下退货：普通顾客签收次日起七天内可以申请，但拆封使用后不支持无理由退货。",
                 "会员申请期是三十天，同样从签收次日起算。质量问题另走售后，不受这条未拆封条件限制。",
                 "保修一年不是一年内都可以退货。申请需提供订单号和商品照片，在订单页联系售后。"]
        result = {"spans": [dict(id=str(uuid.uuid4()), sequence=i, startTime=i*10,
                                 endTime=(i+1)*10, originalText=t) for i, t in enumerate(texts)]}
        manifest["focus_question"] = "我只关心退货怎么申请、期限和例外，不关心摄影技巧。"
    model = pipeline.load_structure_model(manifest)
    calls = 0
    replay = []
    if args.replay_drafts:
        folder = Path(args.replay_drafts).resolve()
        if ROOT / ".build" not in folder.parents or args.transfer_only or args.transfer_check:
            raise ValueError("Replay only accepts isolated course traces")
        for path in sorted(folder.glob("call-*.json"), key=lambda p: int(p.stem.split("-")[-1])):
            trace = json.loads(path.read_bytes())
            if "answer" not in trace:
                raise ValueError("Draft run has not completed")
            replay.append(trace)
        print("EDITOR PROBE: reusing isolated drafts, not full-pipeline acceptance", flush=True)
    started = time.monotonic()

    def traced(llm, system, prompt, schema, **sampling):
        nonlocal calls
        calls += 1
        stamp = time.monotonic()
        payload = dict(system=system, prompt=prompt, schema=schema,
                       sampling={key: value for key, value in sampling.items() if key != "progress_callback"},
                       inputTokens=len(llm.tokenize((system + prompt).encode())))
        path = out / f"call-{calls}.json"
        pipeline.write_result(path, payload)
        print(f"CALL {calls}: {payload['inputTokens']} input tokens", flush=True)
        if "answers" not in schema["properties"] and args.replay_drafts:
            if not replay:
                raise ValueError("Insufficient recorded drafts")
            recorded = replay.pop(0)
            if recorded["schema"] != schema:
                raise ValueError("Recorded draft schema differs")
            if json.loads(recorded["prompt"].split("输入：", 1)[1]) != json.loads(prompt.split("输入：", 1)[1]):
                raise ValueError("Recorded draft evidence/question differs")
            answer = recorded["answer"]
            payload["replayedDraft"] = True
        else:
            if args.replay_drafts and replay:
                raise ValueError("Unconsumed draft traces")
            answer = pipeline.structured_completion(llm, system, prompt, schema, **sampling)
        payload.update(answer=answer, elapsedSeconds=time.monotonic() - stamp)
        pipeline.write_result(path, payload)
        print(f"CALL {calls}: completed in {payload['elapsedSeconds']:.1f}s", flush=True)
        return answer

    traced.supports_progress_callback = True
    result["focusedReport"] = focused_study.generate(model, result["spans"], manifest["focus_question"], traced, pipeline.emit_progress)
    assert source.read_bytes() == before
    pipeline.write_result(out / "result.json", result)
    print(f"COMPLETED (semantic review still required): {len(result['focusedReport']['sections'])} sections; {calls} calls; {time.monotonic() - started:.1f}s", flush=True)
    if args.transfer_check:
        texts = ["今天主要介绍相机的光圈、快门和人像构图。",
                 "另外讲一下退货：普通顾客签收次日起七天内可以申请，但拆封使用后不支持无理由退货。",
                 "会员申请期是三十天，同样从签收次日起算。质量问题另走售后，不受这条未拆封条件限制。",
                 "保修一年不是一年内都可以退货。申请需提供订单号和商品照片，在订单页联系售后。"]
        fixture = [dict(id=str(uuid.uuid4()), sequence=i, startTime=i*10, endTime=(i+1)*10, originalText=t)
                   for i, t in enumerate(texts)]
        report = focused_study.generate(model, fixture, "我只关心退货怎么申请、期限和例外，不关心摄影技巧。", traced, pipeline.emit_progress)
        pipeline.write_result(out / "transfer-report.json", report)
        print("Transfer-domain result saved for inspection", flush=True)


if __name__ == "__main__":
    main()
