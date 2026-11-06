#!/usr/bin/env python3
"""One model per recording; JSON-lines requests, no per-chunk temporary files."""
import contextlib
import json
import os
import sys
import threading
import time

from local_pipeline import transcribe
from apple_speech import AppleSpeechUnavailable


def watch_parent(parent):
    while os.getppid() == parent:
        time.sleep(1)
    os._exit(0)


def serve(input_stream, output_stream, load_model, run_transcription, run_native=None):
    model = None
    model_path = None
    loads = 0
    previous_path = previous_offset = None
    unavailable_native_path = None
    for line in input_stream:
        started = time.monotonic()
        try:
            manifest = json.loads(line)
            with contextlib.redirect_stdout(sys.stderr):
                offset = manifest.get("preview_time_offset")
                current_path = (manifest.get("audio_paths") or [None])[0]
                if previous_path and offset is not None and previous_offset is not None and abs(offset - previous_offset - 15) < 0.25:
                    manifest["preview_previous_audio_path"] = previous_path
                path = manifest["whisper_model_path"]
                native = run_native is not None and manifest.get("apple_speech_path") and manifest.get("apple_speech_path") != unavailable_native_path
                if native:
                    # The native path may fall back internally, but no cached
                    # Whisper model is retained alongside Apple's recognizer.
                    model = None
                    model_path = None
                    try:
                        speakers, spans, warning = run_native(manifest)
                    except AppleSpeechUnavailable:
                        native = False
                        unavailable_native_path = manifest["apple_speech_path"]
                if not native and path != model_path:
                    model = None
                    model = load_model(path, device="cpu")
                    model_path = path
                    loads += 1
                    previous_path = previous_offset = None
                if not native:
                    speakers, spans, warning = run_transcription(manifest, cached_model=model)
                previous_path, previous_offset = current_path, offset
            response = {"speakers": speakers, "spans": spans, "candidates": [],
                        "warnings": [warning], "modelLoads": loads,
                        "elapsedSeconds": time.monotonic() - started}
        except Exception as error:
            previous_path = previous_offset = None
            response = {"error": str(error), "modelLoads": loads}
        output_stream.write(json.dumps(response, ensure_ascii=False) + "\n")
        output_stream.flush()


if __name__ == "__main__":
    threading.Thread(target=watch_parent, args=(os.getppid(),), daemon=True).start()
    def load_whisper(*args, **kwargs):
        import whisper
        return whisper.load_model(*args, **kwargs)
    def native_preview(manifest):
        from apple_speech import transcribe_native
        from local_pipeline import transcript_result, is_obvious_recognition_hallucination
        segments = transcribe_native(manifest)
        for segment in segments:
            segment["is_background"] = is_obvious_recognition_hallucination(segment["text"])
        return transcript_result(segments, preview=True, warning="Mac 本机即时识别")
    serve(sys.stdin, sys.stdout, load_whisper, transcribe, native_preview)
