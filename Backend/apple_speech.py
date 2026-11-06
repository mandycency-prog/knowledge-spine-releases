"""Use installed Apple speech assets only. Never fetch assets or use cloud ASR."""
import json
import os
import subprocess
import tempfile
import wave
from pathlib import Path
from audio_context import RATE, decoded_blocks, owned_segments


class AppleSpeechUnavailable(Exception):
    pass


def native_groups(event):
    """Index recognized words after analysis; never cut the recognizer's input."""
    words = event.get("words") or []
    if not words or "".join(word["word"] for word in words) != event.get("text"):
        # Untimed punctuation/text must not silently disappear in word slicing.
        yield {key: value for key, value in event.items() if key != "words"}
        return
    group = []
    for word in words:
        if group and (float(word["start"]) - float(group[-1]["end"]) >= 0.35 or
                      float(word["end"]) - float(group[0]["start"]) > 12):
            yield {"start": group[0]["start"], "end": group[-1]["end"],
                   "text": "".join(item["word"] for item in group), "words": group}
            group = []
        group.append(word)
    if group:
        yield {"start": group[0]["start"], "end": group[-1]["end"],
               "text": "".join(item["word"] for item in group), "words": group}


def transcribe_native(manifest):
    import numpy as np
    helper = manifest.get("apple_speech_path", "")
    if not helper or not os.access(helper, os.X_OK):
        raise AppleSpeechUnavailable("Apple speech helper unavailable")
    try:
        capability = subprocess.run([helper, "--probe"], capture_output=True, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AppleSpeechUnavailable("Apple speech capability query unavailable") from error
    try:
        info = json.loads(capability.stdout)
    except ValueError:
        raise AppleSpeechUnavailable("Apple speech capability could not be read")
    if capability.returncode != 0 or not info.get("available") or not info.get("installedChinese"):
        raise AppleSpeechUnavailable("Installed Chinese on-device speech is unavailable")
    locations = []
    origin = 0.0
    with tempfile.TemporaryDirectory(prefix="KnowledgeSpine-AppleSpeech-") as temp:
        audio_path = Path(temp) / "continuous.wav"
        with wave.open(str(audio_path), "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(RATE)
            previous = manifest.get("preview_previous_audio_path")
            if previous:
                tail = np.empty(0, dtype=np.float32)
                for block in decoded_blocks([previous], manifest["ffmpeg_path"], []):
                    tail = np.concatenate((tail, block))[-5 * RATE:]
                origin = -len(tail) / RATE
                audio.writeframes((np.clip(tail, -1, 1) * 32767).astype("<i2").tobytes())
            for block in decoded_blocks(manifest["audio_paths"], manifest["ffmpeg_path"], locations):
                audio.writeframes((np.clip(block, -1, 1) * 32767).astype("<i2").tobytes())
        if not locations:
            raise ValueError("No decodable audio samples")
        # Logs stay on disk, not an unbounded pipe; both helper and parent have
        # timeouts. Parent death also cancels the helper's active analyzer.
        events_path = Path(temp) / "events.ndjson"
        with events_path.open("wb") as events:
            outcome = subprocess.run([helper, "--transcribe", str(audio_path), "--timeout-seconds", "1800"],
                                     stdout=events, stderr=subprocess.DEVNULL, timeout=1810)
        raw, complete, file_complete, error = [], False, False, ""
        segment_count = 0
        with events_path.open() as events:
            for line in events:
                item = json.loads(line)
                if complete:
                    raise ValueError("Unexpected event after completion")
                if item.get("event") == "segment":
                    if file_complete:
                        raise ValueError("Unexpected recognition after file completion")
                    segment_count += 1
                    raw.extend(owned_segments({"segments": list(native_groups(item))}, origin, 0, locations[-1][2], locations))
                elif item.get("event") == "fileComplete":
                    if file_complete or item.get("segmentCount") != segment_count:
                        raise ValueError("Recognition segment count mismatch")
                    file_complete = True
                elif item.get("event") == "complete":
                    complete = file_complete and item.get("fileCount") == 1 and item.get("segmentCount") == segment_count
                elif item.get("event") == "error":
                    error = str(item.get("error", "Apple speech failed"))
        if outcome.returncode != 0 or not complete or error:
            raise ValueError(error or "Apple speech stopped before final completion")
        # Keep raw recognition intact. Readable punctuation is a separate field
        # and only uses observed pauses; it never corrects or adds a spoken word.
        for index, segment in enumerate(raw):
            if segment["text"] and segment["text"][-1] not in "。！？.!?,，;；:：":
                gap = raw[index + 1]["start"] - segment["end"] if index + 1 < len(raw) else 1
                # A time-index group may cut through a word (教 / 材). Its
                # boundary alone is never evidence for inserting a comma.
                if gap >= 0.25:
                    segment["punctuated_text"] = segment["text"] + ("。" if gap >= 0.8 else "，")
        return raw
