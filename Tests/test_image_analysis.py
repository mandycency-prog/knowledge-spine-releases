"""Synthetic visual transport and evidence tests; never use personal records."""
import base64
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unittest
from unittest.mock import patch
import uuid
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
import image_analysis as images
import source_bound_map as maps
import focused_study
import remote_model

ROOT = Path(__file__).resolve().parents[1]
FAKE_KEY = "synthetic-image-test-never-real"


def png():
    def chunk(kind, value):
        return struct.pack(">I", len(value)) + kind + value + struct.pack(">I", zlib.crc32(kind + value) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + b"\x20\x60\xa0" * 4) * 4)) + chunk(b"IEND", b""))


def config(base="https://example.invalid/v1"):
    return {"baseURL": base, "approvedEndpoint": base, "approvedImageEndpoint": base,
            "model": "synthetic-vision", "contextWindow": 65536, "maxOutputTokens": 4096}


def attachment(directory, **changes):
    path = Path(directory) / "synthetic.png"
    path.write_bytes(png())
    item = {"id": str(uuid.uuid4()), "path": str(path), "sha256": hashlib.sha256(png()).hexdigest(),
            "fingerprint": "synthetic-v1", "note": "合成课件", "sourceSpanIDs": []}
    item.update(changes)
    return item


def analysis():
    return {"extractedText": "观察、提出假设、实验验证。", "explanation": "图片用箭头连接观察、假设和验证。",
            "uncertainties": ["合成图中的小字不作事实依据。"]}


def speech():
    return {"id": str(uuid.uuid4()), "sequence": 0, "startTime": 12, "endTime": 20,
            "speakerID": str(uuid.uuid4()), "originalText": "这个方法需要反复验证。", "isBackgroundAudio": False,
            "proofreadBasis": "这个方法需要反复验证。", "proofreadText": "这个方法需要反复验证。",
            "proofreadUncertainties": [], "proofreadPunctuatedText": "这个方法需要反复验证。"}


class ImageEvidenceTests(unittest.TestCase):
    def test_validated_cached_analysis_needs_no_key_or_network(self):
        with tempfile.TemporaryDirectory() as directory:
            item = attachment(directory)
            item["analysis"] = dict(id=item["id"], fingerprint=item["fingerprint"], model="synthetic-vision", **analysis())
            with patch.object(images, "RemoteModel") as model:
                result = images.analyze_images({"images": [item], "image_api_configuration": config()})
            model.assert_not_called()
            self.assertEqual(result[0]["id"], item["id"])
            self.assertEqual(result[0]["explanation"], analysis()["explanation"])

    def test_cache_does_not_bypass_file_integrity_or_image_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            item = attachment(directory)
            item["analysis"] = dict(fingerprint=item["fingerprint"], model="synthetic-vision", **analysis())
            for configuration, mutate in [(dict(config(), approvedImageEndpoint=None), False), (config(), True)]:
                target = copy.deepcopy(item)
                if mutate:
                    target["sha256"] = "0" * 64
                with patch.object(images, "RemoteModel") as model, self.assertRaises(ValueError):
                    images.analyze_images({"images": [target], "image_api_configuration": configuration})
                model.assert_not_called()

    def test_invalid_files_types_paths_size_and_crc_fail_before_api(self):
        with tempfile.TemporaryDirectory() as directory:
            base = attachment(directory)
            bad_png = bytearray(png()); bad_png[-1] ^= 1
            for data in (b"GIF89a-not-png", bytes(bad_png), png()[:-1], b"x" * 10_000_001):
                Path(base["path"]).write_bytes(data)
                item = dict(base, sha256=hashlib.sha256(data).hexdigest())
                with self.subTest(size=len(data)), patch.object(images, "RemoteModel") as model, self.assertRaises(ValueError):
                    images.analyze_images({"images": [item], "image_api_configuration": config()})
                model.assert_not_called()
            for path in ("https://example.invalid/image.png", "relative.png"):
                with self.assertRaisesRegex(ValueError, "本地文件"):
                    images._validated_image(dict(base, path=path))

    def test_virtual_evidence_has_no_audio_time_and_never_changes_transcript(self):
        with tempfile.TemporaryDirectory() as directory:
            original = [speech()]
            before = copy.deepcopy(original)
            item = attachment(directory)
            values = [dict(id=item["id"], fingerprint=item["fingerprint"], model="synthetic-vision", **analysis())]
            evidence = images.evidence_spans(original, [item], values)
            self.assertEqual(original, before)
            self.assertEqual(evidence[0]["sourceKind"], "image")
            self.assertNotIn("startTime", evidence[0]); self.assertNotIn("endTime", evidence[0])
            maps._validate_spans(original + evidence)
            units = maps._make_units(original + evidence)
            image_units = [u for u in units if u.get("sourceKind") == "image"]
            self.assertTrue(image_units)
            self.assertTrue(all(u["time"] is None for u in image_units))
            self.assertTrue(all(maps._unit_payload(u)["aiInterpretation"] for u in image_units))
            self.assertTrue(all("time" not in maps._unit_payload(u) for u in image_units))
            records = focused_study._records(original + evidence)
            self.assertIn("图片AI解读", focused_study._compact(records))

    def test_conversion_keeps_real_quotes_and_splits_image_sources(self):
        text_id, image_id = str(uuid.uuid4()), str(uuid.uuid4())
        literal = {"text": "真实引文", "parts": [{"sourceID": text_id, "startOffset": 0, "endOffset": 4}], "time": [1, 2]}
        image_quote = {"text": "图像AI解读", "parts": [{"sourceID": image_id, "startOffset": 0, "endOffset": 6}], "time": None}
        value = {"sourceSpanIDs": [text_id, image_id], "coveredSourceSpanIDs": [image_id, text_id],
                 "coreOriginals": [literal, image_quote], "conditionOriginals": [image_quote]}
        result = images.separate_image_sources(value, {image_id})
        self.assertEqual(result["sourceSpanIDs"], [text_id]); self.assertEqual(result["sourceImageIDs"], [image_id])
        self.assertEqual(result["coveredSourceImageIDs"], [image_id])
        self.assertEqual(result["coreOriginals"], [literal]); self.assertEqual(result["conditionOriginals"], [])
        self.assertEqual(len(value["coreOriginals"]), 2)

    def test_image_extractive_nodes_become_ai_summary_but_audio_only_stays_extracted(self):
        audio_id, image_id = str(uuid.uuid4()), str(uuid.uuid4())
        audio_quote = {"text": "实际合成原话。", "parts": [{"sourceID": audio_id, "startOffset": 0, "endOffset": 7}], "time": [0, 1]}
        image_quote = {"text": "图片模型观察。", "parts": [{"sourceID": image_id, "startOffset": 0, "endOffset": 7}], "time": None}
        for quotes, ids in [([image_quote], [image_id]), ([audio_quote, image_quote], [audio_id, image_id])]:
            value = {"sourceBoundStatus": "extracted", "summary": "\n\n".join(q["text"] for q in quotes),
                     "sourceSpanIDs": ids, "coveredSourceSpanIDs": ids, "coreOriginals": quotes, "conditionOriginals": []}
            result = images.separate_image_sources(value, {image_id})
            self.assertEqual(result["sourceBoundStatus"], "summarized")
            self.assertEqual(result["summary"], value["summary"])
            self.assertEqual(result["coreOriginals"], [q for q in quotes if q is audio_quote])
            self.assertEqual(value["sourceBoundStatus"], "extracted")
        audio = {"sourceBoundStatus": "extracted", "sourceSpanIDs": [audio_id], "summary": audio_quote["text"], "coreOriginals": [audio_quote]}
        self.assertEqual(images.separate_image_sources(audio, {image_id})["sourceBoundStatus"], "extracted")

    def test_text_approval_cannot_grant_image_access_and_keys_do_not_fall_back(self):
        approved = config()
        with patch.dict(os.environ, {"KNOWLEDGE_SPINE_API_KEY": FAKE_KEY, "KNOWLEDGE_SPINE_IMAGE_API_KEY": ""}):
            with self.assertRaises(remote_model.RemoteAPIError):
                remote_model.RemoteModel(approved, image_mode=True)
        with self.assertRaisesRegex(remote_model.RemoteAPIError, "发送图片"):
            remote_model.RemoteModel(dict(approved, approvedImageEndpoint=None), key=FAKE_KEY, image_mode=True)

    def test_partial_success_is_checkpointed_and_invalid_later_file_blocks_all_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            first = attachment(directory)
            second = dict(first, id=str(uuid.uuid4()))
            completed = []
            with patch.object(images, "RemoteModel") as model:
                model.return_value.structured.side_effect = [analysis(), remote_model.RemoteAPIError("synthetic error")]
                with self.assertRaises(remote_model.RemoteAPIError):
                    images.analyze_images({"images": [first, second], "image_api_configuration": config()}, on_result=completed.append)
                self.assertEqual(len(completed), 1); self.assertEqual(completed[0][0]["id"], first["id"])
                model.return_value.close.assert_called_once()
            with patch.object(images, "RemoteModel") as model, self.assertRaises(ValueError):
                images.analyze_images({"images": [first, dict(second, sha256="0" * 64)], "image_api_configuration": config()})
            model.assert_not_called()


class Loopback:
    def __init__(self, status=200):
        self.requests, self.status = [], status
        outer = self
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                value = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.requests.append((self.path, self.headers.get("Authorization"), value))
                content = value["messages"][1]["content"]
                if isinstance(content, list):
                    answer = analysis()
                else:
                    schema = json.loads(content.rsplit("只输出符合以下结构的 JSON，不要附加说明：", 1)[1])
                    fields = schema["properties"]
                    if "sections" in fields:
                        text = content.split("输入：", 1)[1].split("\n只输出符合以下结构", 1)[0]
                        source = json.loads(text)["transcript"]
                        keys = [int(line.split("]", 1)[0][1:]) for line in source.splitlines() if line.startswith("[")]
                        answer = {"sections": [{"heading": "验证方法", "explanation": "根据讲解和图片，观察后提出假设并通过实验验证。", "sourceKeys": keys}], "gaps": []}
                    elif "assignments" in fields:
                        answer = {"stageLabels": {k: "实验验证" if k == "A" else None for k in "ABCDEFG"},
                                  "stageRoles": {k: "执行动作" if k == "A" else None for k in "ABCDEFG"},
                                  "assignments": {k: "A" for k in fields["assignments"]["properties"]}}
                    elif "navigationLabel" in fields:
                        answer = {"navigationLabel": "实验验证", "summary": "通过观察提出假设，并结合实验反复验证。", "argumentSummary": "先观察现象，再提出假设并验证，图片中的疑点需要核对原图。"}
                    elif "branches" in fields:
                        keys = fields["branches"]["items"]["properties"]["sourceKeys"]["items"]["enum"]
                        answer = {"branches": [{"navigationLabel": "观察与验证", "summary": "观察现象后提出假设，并通过实验进行反复验证。", "sourceKeys": keys[:3]}]}
                    else:
                        answer = {stage: {"core": field["properties"]["core"]["items"]["enum"][:3], "conditions": []} for stage, field in fields.items()}
                response = {"choices": [{"finish_reason": "stop", "message": {"content": json.dumps(answer, ensure_ascii=False)}}]}
                self.send_response(outer.status); self.send_header("Content-Type", "application/json"); self.end_headers()
                self.wfile.write(json.dumps(response).encode())
            def log_message(self, *args):
                pass
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}/v1"

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.server.shutdown(); self.server.server_close(); self.thread.join()


class ImageLoopbackProcessTests(unittest.TestCase):
    def run_cli(self, directory, manifest, *flags):
        path = Path(directory) / "manifest.json"; output = Path(directory) / "result.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        env = dict(os.environ, KNOWLEDGE_SPINE_IMAGE_API_KEY=FAKE_KEY, KNOWLEDGE_SPINE_API_KEY="synthetic-text-key", PYTHONDONTWRITEBYTECODE="1")
        process = subprocess.run([sys.executable, "-B", str(ROOT / "Backend/local_pipeline.py"), "--manifest", str(path), "--output", str(output), *flags],
                                 capture_output=True, text=True, timeout=30, env=env)
        result = json.loads(output.read_text()) if output.is_file() else None
        return process, result

    def test_real_subprocess_sends_image_bytes_then_reuses_exact_cache(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            item = attachment(directory)
            manifest = {"images": [item], "image_api_configuration": config(api.base)}
            process, result = self.run_cli(directory, manifest, "--images-only")
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(len(api.requests), 1)
            path, authorization, payload = api.requests[0]
            self.assertEqual(path, "/v1/chat/completions"); self.assertEqual(authorization, "Bearer " + FAKE_KEY)
            parts = payload["messages"][1]["content"]
            url = parts[1]["image_url"]["url"]
            self.assertTrue(url.startswith("data:image/png;base64,"))
            self.assertEqual(base64.b64decode(url.split(",", 1)[1]), png())
            self.assertNotIn(item["path"], json.dumps(payload)); self.assertNotIn(FAKE_KEY, json.dumps(payload))
            self.assertNotIn("base64", process.stdout + process.stderr)
            self.assertEqual(result["spans"], []); self.assertEqual(result["candidates"], [])
            item["analysis"] = result["imageAnalyses"][0]
            second, reused = self.run_cli(directory, manifest, "--images-only")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(len(api.requests), 1); self.assertIn("不重复调用", second.stdout)
            item["fingerprint"] = "changed-note-or-model-v2"
            third, _ = self.run_cli(directory, manifest, "--images-only")
            self.assertEqual(third.returncode, 0, third.stderr); self.assertEqual(len(api.requests), 2)

    def test_failure_is_explicit_no_retry_and_preserves_real_transcript(self):
        with tempfile.TemporaryDirectory() as directory, Loopback(status=400) as api:
            item = attachment(directory); original = speech()
            prior = Path(directory) / "prior.json"; prior.write_text(json.dumps({"spans": [original], "speakers": [], "warnings": []}))
            manifest = {"analysis_provider": "api", "api_configuration": config(api.base), "images": [item], "image_api_configuration": config(api.base)}
            process, result = self.run_cli(directory, manifest, "--structure-from", str(prior))
            self.assertNotEqual(process.returncode, 0); self.assertEqual(len(api.requests), 1)
            self.assertEqual(result["spans"], [original]); self.assertEqual(result["candidates"], [])
            self.assertTrue(result["warnings"]); self.assertNotIn(FAKE_KEY, process.stderr)

    def test_detail_tiles_sent_in_same_request_and_each_hash_checked(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            item = attachment(directory)
            tile = Path(directory) / "detail.png"; tile.write_bytes(png())
            item.update(detailPaths=[str(tile)], detailSHA256=[hashlib.sha256(png()).hexdigest()])
            manifest = {"images": [item], "image_api_configuration": config(api.base)}
            process, _ = self.run_cli(directory, manifest, "--images-only")
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(len(api.requests), 1)
            self.assertEqual(len(api.requests[0][2]["messages"][1]["content"]), 3)
            item["detailSHA256"] = ["0" * 64]
            failed, result = self.run_cli(directory, manifest, "--images-only")
            self.assertNotEqual(failed.returncode, 0); self.assertEqual(len(api.requests), 1)
            self.assertEqual(result["imageAnalyses"], []); self.assertEqual(result["spans"], [])

    def test_images_only_context_is_read_but_not_relabelled_as_returned_transcript(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            original = speech(); item = attachment(directory, sourceSpanIDs=[original["id"]])
            manifest = {"images": [item], "image_api_configuration": config(api.base), "image_context_spans": [original]}
            process, result = self.run_cli(directory, manifest, "--images-only")
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(result["spans"], [])
            self.assertIn(original["originalText"], api.requests[0][2]["messages"][1]["content"][0]["text"])

    def test_images_only_context_uuid_case_matches_swift_and_legacy_checkpoints(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            original = speech()
            for source_case in (str.upper, str.lower):
                for reference_case in (str.upper, str.lower):
                    current = dict(original, id=source_case(original["id"]))
                    item = attachment(directory, sourceSpanIDs=[reference_case(original["id"])])
                    manifest = {"images": [item], "image_api_configuration": config(api.base), "image_context_spans": [current]}
                    process, result = self.run_cli(directory, manifest, "--images-only")
                    self.assertEqual(process.returncode, 0, process.stderr)
                    self.assertEqual(result["spans"], [])
                    self.assertIn(original["originalText"], api.requests[-1][2]["messages"][1]["content"][0]["text"])
            self.assertEqual(len(api.requests), 4)

    def test_real_extractive_maps_with_images_are_not_published_as_exact_audio(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            item = attachment(directory)
            for real in ([], [speech()]):
                before = copy.deepcopy(real)
                decoded = [dict(id=item["id"], fingerprint=item["fingerprint"], model="synthetic-vision", **analysis())]
                image_spans = images.evidence_spans(real, [item], decoded)
                model = remote_model.RemoteModel(config(api.base), key="synthetic-text-key")
                try:
                    extracted, _ = maps.build_map(model, real + image_spans,
                        lambda llm, system, prompt, schema, **kwargs: llm.structured(system, prompt, schema, **kwargs),
                        "合成图片摘录测试", synthesize=False, expand_branches=False)
                finally:
                    model.close()
                self.assertTrue(any(n.get("sourceBoundStatus") == "extracted" for n in extracted))
                published = images.separate_image_sources(extracted, {item["id"]})
                stages = [n for n in published if n.get("sourceBoundStatus")]
                self.assertTrue(stages)
                self.assertTrue(all(n["sourceBoundStatus"] == "summarized" for n in stages))
                self.assertTrue(all(item["id"] in n.get("sourceImageIDs", []) for n in stages))
                quotes = [q for n in stages for q in n.get("coreOriginals", [])]
                self.assertTrue(all(p["sourceID"] in {s["id"] for s in real} for q in quotes for p in q["parts"]))
                if real:
                    self.assertTrue(quotes)
                else:
                    self.assertEqual(quotes, [])
                self.assertEqual(real, before)

    def test_relistening_clears_preview_ids_and_reanchors_to_new_transcript(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            old = speech(); item = attachment(directory, sourceSpanIDs=[old["id"]], anchorTime=15)
            manifest = {"images": [item], "image_api_configuration": config(api.base), "image_context_spans": [old]}
            first, result = self.run_cli(directory, manifest, "--images-only")
            self.assertEqual(first.returncode, 0, first.stderr)
            item["analysis"] = result["imageAnalyses"][0]
            # The caller discards stale preview identity/cache when ASR starts
            # again; the anchor then resolves against the newly produced text.
            item.pop("analysis"); item["sourceSpanIDs"] = []
            new = dict(old, id=str(uuid.uuid4()), originalText="新的讲解说明实验需要设置对照。")
            manifest["image_context_spans"] = [new]
            second, _ = self.run_cli(directory, manifest, "--images-only")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(len(api.requests), 2)
            prompt = api.requests[-1][2]["messages"][1]["content"][0]["text"]
            self.assertIn(new["originalText"], prompt); self.assertNotIn(old["originalText"], prompt)

    def test_mixed_map_preserves_real_quotes_and_image_source_links(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            item = attachment(directory); original = speech()
            prior = Path(directory) / "prior.json"; prior.write_text(json.dumps({"spans": [original], "speakers": [], "warnings": []}))
            manifest = {"analysis_provider": "api", "api_configuration": config(api.base), "images": [item],
                        "image_api_configuration": config(api.base), "session_title": "合成图文课程",
                        "reuse_transcript_classification": True, "reuse_existing_proofreading": True}
            process, result = self.run_cli(directory, manifest, "--structure-from", str(prior))
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(result["spans"], [original])
            all_quotes = [q for n in result["candidates"] for field in ("coreOriginals", "conditionOriginals") for q in n.get(field, [])]
            self.assertTrue(all_quotes)
            self.assertTrue(all(p["sourceID"] == original["id"] for q in all_quotes for p in q["parts"]))
            self.assertTrue(any(item["id"] in n.get("sourceImageIDs", []) for n in result["candidates"]))
            self.assertTrue(any(original["id"] in n["sourceSpanIDs"] for n in result["candidates"]))

    def test_mixed_focused_report_uses_both_evidence_types_without_fake_spans(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            item = attachment(directory); original = speech()
            item["sourceSpanIDs"] = [original["id"]]
            prior = Path(directory) / "prior.json"; prior.write_text(json.dumps({"spans": [original], "speakers": [], "warnings": []}))
            manifest = {"analysis_provider": "api", "api_configuration": config(api.base), "images": [item],
                        "image_api_configuration": config(api.base), "focus_question": "如何验证假设？"}
            process, result = self.run_cli(directory, manifest, "--structure-from", str(prior))
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(len(api.requests), 2)
            self.assertEqual(result["spans"], [original])
            section = result["focusedReport"]["sections"][0]
            self.assertEqual(section["sourceSpanIDs"], [original["id"]]); self.assertEqual(section["sourceImageIDs"], [item["id"]])
            visual_text = api.requests[0][2]["messages"][1]["content"][0]["text"]
            self.assertIn(original["originalText"], visual_text)
            self.assertEqual(api.requests[1][1], "Bearer synthetic-text-key")

    def test_pure_image_course_builds_map_and_focused_answer_without_audio(self):
        with tempfile.TemporaryDirectory() as directory, Loopback() as api:
            item = attachment(directory)
            manifest = {"analysis_provider": "api", "api_configuration": config(api.base), "images": [item],
                        "image_api_configuration": config(api.base), "session_title": "合成图文课程"}
            process, result = self.run_cli(directory, manifest)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(result["spans"], []); self.assertTrue(result["candidates"])
            image_nodes = [n for n in result["candidates"] if item["id"] in n.get("sourceImageIDs", [])]
            self.assertTrue(image_nodes)
            for node in result["candidates"]:
                self.assertEqual(node["sourceSpanIDs"], [])
                self.assertFalse(node.get("coreOriginals")); self.assertFalse(node.get("conditionOriginals"))
            item["analysis"] = result["imageAnalyses"][0]
            prior = Path(directory) / "prior.json"; prior.write_text(json.dumps({"spans": [], "speakers": [], "warnings": []}))
            manifest["focus_question"] = "图中方法是什么？"
            focused, report = self.run_cli(directory, manifest, "--structure-from", str(prior))
            self.assertEqual(focused.returncode, 0, focused.stderr)
            self.assertEqual(report["focusedReport"]["sections"][0]["sourceSpanIDs"], [])
            self.assertEqual(report["focusedReport"]["sections"][0]["sourceImageIDs"], [item["id"]])


if __name__ == "__main__":
    unittest.main()
