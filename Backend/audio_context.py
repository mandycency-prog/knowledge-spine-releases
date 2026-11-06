"""Bounded continuous audio windows, independent of crash-safe file chunks."""
import subprocess
import tempfile

RATE = 16000


def decoded_blocks(paths, ffmpeg, locations):
    """Stream one file at a time; even a four-hour imported file stays bounded."""
    import numpy as np
    cursor = 0
    for path in paths:
        start = cursor
        location_index = None
        with tempfile.TemporaryFile() as errors:
            child = subprocess.Popen([ffmpeg, "-nostdin", "-v", "error", "-i", path,
                                      "-f", "f32le", "-ac", "1", "-ar", str(RATE), "pipe:1"],
                                     stdout=subprocess.PIPE, stderr=errors)
            try:
                while True:
                    data = child.stdout.read(RATE * 4 * 10)
                    if not data:
                        break
                    if len(data) % 4:
                        raise ValueError("Audio decoder returned an incomplete sample")
                    block = np.frombuffer(data, dtype="<f4")
                    cursor += len(block)
                    # Update this while yielding so timestamps can be mapped
                    # even before a long input file finishes decoding.
                    if location_index is not None:
                        locations[location_index] = (path, start / RATE, cursor / RATE)
                    else:
                        location_index = len(locations)
                        locations.append((path, start / RATE, cursor / RATE))
                    yield block
                if child.wait() != 0:
                    errors.seek(0)
                    raise ValueError("Audio decoding failed: " + errors.read(2000).decode("utf-8", errors="replace"))
            finally:
                child.stdout.close()
                if child.poll() is None:
                    child.kill()
                    child.wait()


def context_windows(blocks, core_seconds=90, overlap_seconds=5):
    """Every sample has one owner; adjacent windows hear both sides of a cut."""
    import numpy as np
    core, overlap = int(core_seconds * RATE), int(overlap_seconds * RATE)
    if core <= 0 or overlap < 0 or overlap >= core:
        raise ValueError("Invalid audio window sizes")
    buffer = np.empty(0, dtype=np.float32)
    origin = owner = 0
    for block in blocks:
        buffer = np.concatenate((buffer, block))
        while origin + len(buffer) >= owner + core + overlap:
            end = owner + core + overlap
            yield buffer[:end - origin].copy(), origin / RATE, owner / RATE, (owner + core) / RATE
            owner += core
            keep = owner - overlap
            buffer = buffer[keep - origin:].copy()
            origin = keep
    end = origin + len(buffer)
    if end > owner:
        yield buffer, origin / RATE, owner / RATE, end / RATE


def owned_segments(result, origin, start, end, locations):
    """Discard context-only words, never invent or spell-correct the ASR text."""
    for segment in result.get("segments", []):
        words = segment.get("words") or []
        if words:
            selected = [word for word in words
                        if start <= origin + (float(word["start"]) + float(word["end"])) / 2 < end]
            if not selected:
                continue
            text = "".join(str(word["word"]) for word in selected).strip()
            begin = origin + float(selected[0]["start"])
            finish = origin + float(selected[-1]["end"])
        else:
            begin, finish = origin + float(segment["start"]), origin + float(segment["end"])
            if not start <= (begin + finish) / 2 < end:
                continue
            text = str(segment.get("text", "")).strip()
        if not text:
            continue
        midpoint = (begin + finish) / 2
        source = next((item for item in locations if item[1] <= midpoint < item[2]), locations[-1])
        yield {"start": max(0, begin), "end": min(locations[-1][2], finish), "text": text,
               "audio_path": source[0], "local_start": max(0, begin - source[1]),
               "local_end": min(source[2] - source[1], finish - source[1])}
