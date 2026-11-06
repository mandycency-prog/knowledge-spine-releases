#!/usr/bin/env python3
"""Apply one verified local-pipeline result to a copied KnowledgeSpine DB.

This is a recovery/migration utility, not part of normal capture. It preserves
audio, settings, transcript corrections, important marks, and user thoughts;
the old map is stored as a restorable version before replacement.
"""

import argparse
import json
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--structure-model-path")
    return parser.parse_args()


def parse_date(value):
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def iso_date(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def make_node(*, source_ids, kind, parent_id, relation, position, confidence=None,
              text=None, secondary=False, manual_at=None, label=None,
              thought_id=None, important_mark_id=None, node_id=None,
              ai_summary=None):
    return {
        "id": node_id or str(uuid.uuid4()).upper(),
        "sourceSpanIDs": source_ids,
        "kind": kind,
        "parentID": parent_id,
        "relation": relation,
        "confidence": confidence,
        "position": {"x": float(position[0]), "y": float(position[1])},
        "isCollapsed": False,
        "userEditedText": text,
        "aiSummary": ai_summary,
        "isSecondaryEdit": secondary,
        "isDeleted": False,
        "manualRevisionAt": manual_at,
        "userLabel": label,
        "thoughtID": thought_id,
        "importantMarkID": important_mark_id,
    }


def layout_mind_map(nodes):
    """Lay out one stable left-to-right tree instead of a chronological grid."""
    by_id = {item["id"]: item for item in nodes}
    children = {item["id"]: [] for item in nodes}
    roots = []
    for item in nodes:
        parent_id = item.get("parentID")
        if parent_id in by_id:
            children[parent_id].append(item["id"])
        else:
            roots.append(item["id"])

    next_leaf_y = 170.0
    visiting = set()

    def place(node_id, depth):
        nonlocal next_leaf_y
        node = by_id[node_id]
        if node_id in visiting:
            node["parentID"] = None
            node["relation"] = "root"
            y = next_leaf_y
            next_leaf_y += 190.0
            node["position"] = {"x": 190.0 + depth * 360.0, "y": y}
            return y
        visiting.add(node_id)
        child_ids = children.get(node_id, [])
        if child_ids:
            child_positions = [place(child_id, depth + 1) for child_id in child_ids]
            y = (child_positions[0] + child_positions[-1]) / 2.0
        else:
            y = next_leaf_y
            next_leaf_y += 190.0
        visiting.remove(node_id)
        node["position"] = {"x": 190.0 + depth * 360.0, "y": y}
        return y

    for root_id in roots:
        place(root_id, 0)


def main():
    args = parse_args()
    database = json.loads(Path(args.database).read_text(encoding="utf-8"))
    result = json.loads(Path(args.result).read_text(encoding="utf-8"))
    if args.structure_model_path:
        database.setdefault("settings", {})["structureModelPath"] = args.structure_model_path
    session = next(item for item in database["sessions"] if item["id"] == args.session)
    old_spans = session.get("transcript", [])
    old_by_sequence = {item["sequence"]: item for item in old_spans}

    new_spans = sorted(result["spans"], key=lambda item: item["sequence"])
    id_map = {}
    for span in new_spans:
        old = old_by_sequence.get(span["sequence"])
        if old and abs(float(old["startTime"]) - float(span["startTime"])) < 1.5:
            id_map[span["id"]] = old["id"]
            span["id"] = old["id"]
            span["correctedText"] = old.get("correctedText")
            span["isImportant"] = bool(old.get("isImportant", False))

    valid_span_ids = {item["id"] for item in new_spans}
    for mark in session.get("importantMarks") or []:
        mark["protectedSpanIDs"] = [value for value in mark["protectedSpanIDs"] if value in valid_span_ids]
        for span in new_spans:
            if span["id"] in mark["protectedSpanIDs"]:
                span["isImportant"] = True
    session["importantMarks"] = [
        mark for mark in (session.get("importantMarks") or []) if mark["protectedSpanIDs"]
    ]

    speakers = result.get("speakers", [])
    old_speakers = session.get("speakers", [])
    for index, speaker in enumerate(speakers):
        if index < len(old_speakers):
            speaker["displayName"] = old_speakers[index]["displayName"]
            speaker["role"] = old_speakers[index]["role"]

    now = iso_date(datetime.now(timezone.utc))
    versions = session.setdefault("versions", [])
    versions.append({
        "id": str(uuid.uuid4()).upper(),
        "createdAt": now,
        "reason": "真实录音背景过滤与导图重建前",
        "nodes": session.get("nodes", []),
        "thoughts": session.get("thoughts", []),
    })
    if len(versions) > 50:
        del versions[:-50]

    nodes = []
    for index, candidate in enumerate(result.get("candidates", [])):
        source_ids = [id_map.get(value, value) for value in candidate["sourceSpanIDs"]]
        if not source_ids or any(value not in valid_span_ids for value in source_ids):
            continue
        nodes.append(make_node(
            node_id=candidate["nodeID"],
            source_ids=source_ids,
            kind=candidate["kind"],
            parent_id=candidate.get("parentID"),
            relation="child" if candidate["relation"] == "expands" else candidate["relation"],
            confidence=candidate.get("confidence"),
            position=(180 + (index % 5) * 340, 190 + (index // 5) * 220),
            ai_summary=candidate.get("summary"),
        ))

    node_ids = {item["id"] for item in nodes}
    for node in nodes:
        if node["parentID"] not in node_ids:
            node["parentID"] = None
            node["relation"] = "root"

    spans_by_id = {item["id"]: item for item in new_spans}

    def node_time(node):
        spans = [spans_by_id[value] for value in node["sourceSpanIDs"] if value in spans_by_id]
        if not spans:
            return None
        return sum((float(item["startTime"]) + float(item["endTime"])) / 2 for item in spans) / len(spans)

    def nearest_main(anchor):
        mains = [item for item in nodes if item["kind"] == "主线" and item["sourceSpanIDs"]]
        pool = mains or [item for item in nodes if item["sourceSpanIDs"]]
        if not pool:
            return None
        return min(pool, key=lambda item: abs((node_time(item) or anchor) - anchor))

    base_max_y = max((item["position"]["y"] for item in nodes), default=190)
    important_y = base_max_y + 220
    for index, mark in enumerate(session["importantMarks"]):
        source_ids = mark["protectedSpanIDs"]
        anchor_span = spans_by_id.get(mark.get("anchorSpanID")) or spans_by_id[source_ids[0]]
        anchor = (float(anchor_span["startTime"]) + float(anchor_span["endTime"])) / 2
        parent = nearest_main(anchor)
        nodes.append(make_node(
            source_ids=source_ids,
            kind="证据",
            parent_id=parent["id"] if parent else None,
            relation="supports" if parent else "root",
            position=(250 + (index % 5) * 330, important_y + (index // 5) * 190),
            manual_at=mark["createdAt"],
            label="重点",
            important_mark_id=mark["id"],
        ))

    max_end = max((float(item["endTime"]) for item in new_spans), default=0)
    ended_at = parse_date(session.get("endedAt"))
    recording_start = ended_at - timedelta(seconds=max_end) if ended_at and max_end else None
    mark_rows = max(1, (len(session["importantMarks"]) + 4) // 5)
    thought_y = important_y + mark_rows * 190 + 30
    for index, thought in enumerate(session.get("thoughts", [])):
        if thought.get("isDeleted"):
            continue
        if thought.get("anchorTime") is None and recording_start:
            created_at = parse_date(thought.get("createdAt"))
            if created_at:
                thought["anchorTime"] = min(max((created_at - recording_start).total_seconds(), 0), max_end)
        anchor = float(thought.get("anchorTime") or 0)
        parent = nearest_main(anchor)
        nodes.append(make_node(
            source_ids=[],
            kind="我的思考",
            parent_id=parent["id"] if parent else None,
            relation="userThought" if parent else "root",
            position=(250 + (index % 5) * 330, thought_y + (index // 5) * 190),
            text=thought["text"],
            secondary=bool(thought.get("isSecondaryEdit", False)),
            manual_at=thought["createdAt"],
            thought_id=thought["id"],
        ))

    layout_mind_map(nodes)

    session["speakers"] = speakers
    session["transcript"] = new_spans
    session["nodes"] = nodes
    session["candidateVersions"] = []
    session["pendingImportantTimes"] = []
    session["transcriptComplete"] = True
    session["structureSaved"] = True
    session["status"] = "结构已保存"
    session["updatedAt"] = now

    output = Path(args.output)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(database, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(output)


if __name__ == "__main__":
    main()
