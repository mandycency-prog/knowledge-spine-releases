"""Reapply deterministic insertion guards to saved text completions; no model."""
import copy
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import punctuation_formatter as formatter


def main():
    source, calls_path, output = [Path(p).resolve() for p in sys.argv[1:]]
    assert all(ROOT / ".build" in path.parents for path in (source, calls_path, output))
    assert not output.exists()
    before = source.read_bytes()
    original = json.loads(before)
    result = copy.deepcopy(original)
    calls = [c for c in json.loads(calls_path.read_text()) if "text" in c["schema"].get("properties", {})]
    for span in result["spans"]:
        if formatter._eligible(span):
            span.pop("proofreadPunctuatedText", None)
    consumed, mismatches = [], []
    def saved_completion(llm, system, prompt, schema, **sampling):
        index = len(consumed)
        consumed.append(index)
        if index >= len(calls):
            mismatches.append(index)
            raise ValueError("Missing recorded input")
        call = calls[index]
        actual = json.loads(prompt.split("连续原稿：", 1)[1])
        prior = json.loads(call["prompt"].split("连续原稿：", 1)[1])
        if actual != prior:
            mismatches.append(index)
            raise ValueError("Recorded source text mismatch")
        if "error" in call:
            raise ValueError("Recorded punctuation call did not finish")
        return copy.deepcopy(call["result"])
    warnings = formatter.punctuate_transcript(None, result["spans"], saved_completion)
    assert not mismatches and len(consumed) == len(calls)
    for old, fresh in zip(original["spans"], result["spans"]):
        assert {k: v for k, v in old.items() if k != "proofreadPunctuatedText"} == {k: v for k, v in fresh.items() if k != "proofreadPunctuatedText"}
        if formatter._eligible(fresh):
            assert formatter.insertion_only(formatter._base(fresh), fresh["proofreadPunctuatedText"])
    assert result["candidates"] == original["candidates"]
    result["warnings"] = [w for w in result.get("warnings", []) if not re.match(r"^第\d+批断句", w)] + warnings
    with output.open("x") as file:
        json.dump(result, file, ensure_ascii=False, indent=2)
    assert source.read_bytes() == before
    print(json.dumps({"inputSHA256": hashlib.sha256(before).hexdigest(), "recordedBatches": len(consumed),
                      "newModelCalls": 0, "rawWordsAndMapUnchanged": True, "warnings": warnings}, ensure_ascii=False))


if __name__ == "__main__":
    main()
