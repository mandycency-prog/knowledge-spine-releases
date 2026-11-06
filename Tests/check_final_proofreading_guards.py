"""Apply current deterministic reading guards to an isolated processing result.

Useful when a long-running job began before a guard-only software update.
No model calls, summary rewrites, or writes to the input/formal database.
"""
import copy
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Backend"))
import transcript_proofreader as proofreader


def main():
    if len(sys.argv) != 3:
        raise ValueError("Provide input-result and fresh-output absolute .build paths")
    build = (ROOT / ".build").resolve()
    source, output = [Path(p).resolve() for p in sys.argv[1:]]
    if any(not p.startswith("/") for p in sys.argv[1:]) or any(build not in p.parents for p in (source, output)):
        raise ValueError("Only explicit isolated project .build paths are allowed")
    if output.exists() or source == output:
        raise ValueError("Refusing overwrite")
    before = source.read_bytes()
    original = json.loads(before)
    result = copy.deepcopy(original)
    context = "\n".join(s["originalText"] for s in result["spans"])
    restored = []
    for span in result["spans"]:
        if not proofreader.valid_proofread(span):
            continue
        issue = proofreader._edit_issue(span["originalText"], span["proofreadText"], context)
        if not issue:
            continue
        span["proofreadText"] = span["originalText"]
        span["proofreadUncertainties"] = list(dict.fromkeys(span["proofreadUncertainties"] + [issue]))
        result["warnings"].append(f"逐字稿第{span['sequence']}段：{issue}")
        restored.append(span["id"])
    # Prove the operation changed only automatic readings/uncertainties and
    # warning text. Model maps, all original/manual fields and IDs stay intact.
    comparable = copy.deepcopy(result)
    comparable["warnings"] = original["warnings"]
    for old, new in zip(original["spans"], comparable["spans"]):
        for key in ("proofreadText", "proofreadUncertainties"):
            if key in old:
                new[key] = old[key]
            else:
                new.pop(key, None)
    if comparable != original or source.read_bytes() != before:
        raise ValueError("Protected input changed")
    with output.open("x", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)
    print(json.dumps({"inputSHA256": hashlib.sha256(before).hexdigest(),
                      "restoredUncertainSourceIDs": restored,
                      "unchangedModelMap": True,
                      "output": str(output)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
