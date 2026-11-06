#!/usr/bin/env python3
"""Atomically attach a validated offline pipeline result to one local session."""

import argparse
import datetime as dt
import json
import os
import tempfile
import uuid
from pathlib import Path


def args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--session-id", required=True)
    return parser.parse_args()


def layout(index, kind):
    if kind == "主线":
        return {"x": 160 + (index % 4) * 350, "y": 230 + (index // 4) * 240}
    if kind == "支线":
        return {"x": 300 + (index % 4) * 350, "y": 500 + (index // 4) * 230}
    return {"x": 190 + (index % 4) * 350, "y": 660 + (index // 4) * 220}


def main():
    options = args()
    database_path = Path(options.database)
    database = json.loads(database_path.read_text(encoding="utf-8"))
    result = json.loads(Path(options.result).read_text(encoding="utf-8"))
    session = next((item for item in database.get("sessions", []) if item.get("id", "").upper() == options.session_id.upper()), None)
    if session is None:
        raise ValueError("session not found")

    spans = result.get("spans", [])
    candidates = result.get("candidates", [])
    valid_span_ids = {item["id"] for item in spans}
    node_ids = {item["nodeID"] for item in candidates}
    if not spans or not candidates:
        raise ValueError("pipeline result is incomplete")
    for node in candidates:
        if not node.get("sourceSpanIDs") or any(value not in valid_span_ids for value in node["sourceSpanIDs"]):
            raise ValueError("candidate contains an invalid source id")
        if node.get("parentID") is not None and node["parentID"] not in node_ids:
            raise ValueError("candidate contains an invalid parent id")

    speakers = result.get("speakers", [])
    old_speakers = session.get("speakers", [])
    for index, speaker in enumerate(speakers):
        if index < len(old_speakers):
            speaker["displayName"] = old_speakers[index].get("displayName", speaker.get("displayName"))
            speaker["role"] = old_speakers[index].get("role", speaker.get("role"))

    nodes = []
    for index, candidate in enumerate(candidates):
        nodes.append({
            "id": candidate["nodeID"],
            "sourceSpanIDs": candidate["sourceSpanIDs"],
            "kind": candidate["kind"],
            "parentID": candidate.get("parentID"),
            "relation": candidate["relation"],
            "confidence": candidate.get("confidence"),
            "position": layout(index, candidate["kind"]),
            "isCollapsed": False,
            "isSecondaryEdit": False,
            "isDeleted": False,
        })

    pending_times = session.get("pendingImportantTimes", []) or []
    marks = session.get("importantMarks", []) or []
    for timestamp in pending_times:
        anchor = min(range(len(spans)), key=lambda index: abs((spans[index]["startTime"] + spans[index]["endTime"]) / 2 - timestamp))
        indexes = range(max(0, anchor - 2), min(len(spans), anchor + 3))
        protected = [spans[index]["id"] for index in indexes]
        for index in indexes:
            spans[index]["isImportant"] = True
        marks.append({
            "id": str(uuid.uuid4()),
            "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "anchorSpanID": spans[anchor]["id"],
            "protectedSpanIDs": protected,
        })

    session["speakers"] = speakers
    session["transcript"] = spans
    session["nodes"] = nodes
    session["importantMarks"] = marks
    session["pendingImportantTimes"] = []
    session["transcriptComplete"] = True
    session["structureSaved"] = True
    session["filesComplete"] = True
    session["status"] = "结构已保存"
    session["updatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    database["schemaVersion"] = 2

    encoded = json.dumps(database, ensure_ascii=False, indent=2).encode("utf-8")
    with tempfile.NamedTemporaryFile(dir=database_path.parent, prefix="database-", suffix=".tmp", delete=False) as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
        temporary = Path(handle.name)
    temporary.replace(database_path)
    print(json.dumps({"session": session["title"], "spans": len(spans), "nodes": len(nodes)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
