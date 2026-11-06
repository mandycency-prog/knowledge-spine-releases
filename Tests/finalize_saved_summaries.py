"""Apply the production title guard to saved AI output, without inference."""
import copy
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
from source_bound_map import sanitize_unknown_titles


def main():
    source, output = map(lambda p: Path(p).resolve(), sys.argv[1:])
    assert ROOT / ".build" in source.parents and ROOT / ".build" in output.parents
    assert not output.exists() and source != output
    before = source.read_bytes()
    result = json.loads(before)
    original = copy.deepcopy(result)
    spans = {s["id"]: s for s in result["spans"]}
    changed = []
    for node in result["candidates"]:
        if node.get("sourceBoundStatus") != "summarized":
            continue
        context = "\n".join(spans[key].get("correctedText") or spans[key]["originalText"]
                            for key in node["sourceSpanIDs"])
        for field in ("navigationLabel", "summary", "argumentSummary"):
            text = node.get(field, "")
            guarded = sanitize_unknown_titles(text, context)
            if guarded != text:
                node[field] = guarded
                changed.append({"nodeID": node["nodeID"], "field": field})
    for old, new in zip(original["candidates"], result["candidates"]):
        for key in old.keys() | new.keys():
            if key not in ("navigationLabel", "summary", "argumentSummary"):
                assert old.get(key) == new.get(key)
    assert {k: v for k, v in original.items() if k != "candidates"} == {k: v for k, v in result.items() if k != "candidates"}
    with output.open("x") as file:
        json.dump(result, file, ensure_ascii=False, indent=2)
    assert source.read_bytes() == before
    print(json.dumps({"inputSHA256": hashlib.sha256(before).hexdigest(), "changedAIFields": changed,
                      "rawAndUserDataUnchanged": True, "modelCalls": 0}, ensure_ascii=False))


if __name__ == "__main__":
    main()
