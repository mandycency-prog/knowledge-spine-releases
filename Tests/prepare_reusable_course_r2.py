"""Prepare R2 sources and a provenance-bearing composite; never run a model.

Only the .input.json fixture is opened. No expected labels are consulted.
This constructs a deterministic test stimulus, not a production merger test.
"""
import argparse
import copy
import hashlib
import json
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Tests/Fixtures/reusable_course_r2.input.json"
STAMP = "2026-09-12T00:00:00Z"


def record(record_id, title, speakers, spans, combined=False):
    return {"id": record_id, "title": title, "createdAt": STAMP, "updatedAt": STAMP,
            "sourceName": "独立合成课程 R2", "sourceKind": "综合记录" if combined else "文本验收",
            "status": "需要处理", "speakers": speakers, "transcript": spans,
            "nodes": [], "thoughts": [], "importantMarks": [], "versions": [],
            "audioRelativePaths": [], "audioState": "none", "transcriptComplete": True,
            "structureSaved": False, "filesComplete": True, "isMergedRecord": combined}


def prepare(payload):
    namespace = uuid.UUID(payload["combinedSessionID"])
    sources, merged_spans, merged_speakers = [], [], []
    offset = 0.0
    for course in payload["courses"]:
        speaker = copy.deepcopy(course["speaker"])
        spans = []
        for raw in course["spans"]:
            span = copy.deepcopy(raw)
            span.update(speakerID=speaker["id"], isImportant=False, isBackgroundAudio=False)
            spans.append(span)
        sources.append(record(course["id"], course["title"], [speaker], spans))
        copied_speaker = dict(speaker, id=str(uuid.uuid5(namespace, speaker["id"])).upper())
        merged_speakers.append(copied_speaker)
        for span in spans:
            copied = copy.deepcopy(span)
            copied.update(id=str(uuid.uuid5(namespace, span["id"])).upper(),
                          sequence=len(merged_spans) + 1, speakerID=copied_speaker["id"],
                          startTime=span["startTime"] + offset, endTime=span["endTime"] + offset,
                          origin={"sessionID": course["id"], "sessionTitle": course["title"],
                                  "itemID": span["id"], "startTime": span["startTime"]})
            merged_spans.append(copied)
        offset += max(span["endTime"] for span in spans) + 1
    combined = record(payload["combinedSessionID"], payload["combinedTitle"], merged_speakers, merged_spans, True)
    return sources + [combined]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--sources-only", action="store_true", help="Prepare only original courses for the actual App integration workflow")
    parser.add_argument("--app-settings-from", help="Read only local runtime settings from a database snapshot")
    args = parser.parse_args()
    out = Path(args.output_dir).resolve()
    if ROOT / ".build" not in out.parents:
        raise ValueError("Output must be a fresh project .build subdirectory")
    raw = FIXTURE.read_bytes()
    payload = json.loads(raw)
    sessions = prepare(payload)
    if args.sources_only:
        sessions = sessions[:-1]
    database = {"schemaVersion": 2, "sessions": sessions, "settings": {
        "structureModelPath": args.model_path, "pythonPath": "", "whisperModelPath": "", "ffmpegPath": ""}}
    if args.app_settings_from:
        database["settings"] = copy.deepcopy(json.loads(Path(args.app_settings_from).read_bytes())["settings"])
        database["settings"]["structureModelPath"] = args.model_path
    out.mkdir(parents=True, exist_ok=False)
    (out / "database.json").write_text(json.dumps(database, ensure_ascii=False, indent=2))
    (out / "provenance.json").write_text(json.dumps({"fixtureID": payload["fixtureID"],
        "inputSHA256": hashlib.sha256(raw).hexdigest(), "sessionID": payload["combinedSessionID"],
        "sourceSessionIDs": [s["id"] for s in sessions if not s.get("isMergedRecord")],
        "sourcesOnly": args.sources_only, "answersRead": False, "modelRun": False}, indent=2))
    print(json.dumps({"database": str(out / "database.json"), "sessionID": payload["combinedSessionID"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
