"""Prepare an isolated real-model input without reading independent answers.

This does not run a model. Pass output/database.json to check_discourse_real.py.
The only fixture opened here is reusable_course_r1.input.json.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Tests/Fixtures/reusable_course_r1.input.json"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    out = Path(args.output_dir).resolve()
    if ROOT / ".build" not in out.parents:
        raise ValueError("Output must be a fresh project .build subdirectory")
    data = FIXTURE.read_bytes()
    source = json.loads(data)
    session = copy.deepcopy(source["session"])
    stamp = "2026-09-12T00:00:00Z"
    session.update(createdAt=stamp, updatedAt=stamp, sourceName="独立合成短课 R1", sourceKind="文本验收",
                   status="需要处理", nodes=[], versions=[], audioRelativePaths=[], audioState="none",
                   transcriptComplete=True, structureSaved=False, filesComplete=True, isMergedRecord=False)
    for thought in session["thoughts"]:
        thought.update(createdAt=stamp, isSecondaryEdit=True)
    for mark in session["importantMarks"]:
        mark["createdAt"] = stamp
    database = {"schemaVersion": 2, "sessions": [session], "settings": {
        "structureModelPath": args.model_path, "pythonPath": "", "whisperModelPath": "", "ffmpegPath": ""}}
    out.mkdir(parents=True, exist_ok=False)
    (out / "database.json").write_text(json.dumps(database, ensure_ascii=False, indent=2))
    (out / "provenance.json").write_text(json.dumps({"fixtureID": source["fixtureID"],
        "inputSHA256": hashlib.sha256(data).hexdigest(), "sessionID": session["id"],
        "answersRead": False, "modelRun": False}, indent=2))
    print(json.dumps({"database": str(out / "database.json"), "sessionID": session["id"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
