"""Explicit local integration check: two real chunks, one actual model load."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("manifest")
args = parser.parse_args()
manifest = json.loads(Path(args.manifest).read_text())
requests = []
for audio in manifest["audio_paths"][30:32]:
    assert Path(audio).is_file(), audio
    requests.append({**manifest, "audio_paths": [audio]})
assert len(requests) == 2
worker = Path(__file__).resolve().parents[1] / "Backend/live_worker.py"
process = subprocess.Popen([sys.executable, "-u", str(worker)], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
try:
    output, _ = process.communicate("\n".join(map(json.dumps, requests)) + "\n", timeout=180)
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
results = [json.loads(line) for line in output.splitlines()]
assert process.returncode == 0
assert len(results) == 2
assert all("error" not in result and result["modelLoads"] == 1 for result in results), results
assert any(result["spans"] for result in results), "Real speech did not produce any spans"
print(json.dumps({"modelLoads": 1, "chunks": 2,
                  "spansPerChunk": [len(r["spans"]) for r in results],
                  "secondsPerChunk": [round(r["elapsedSeconds"], 2) for r in results]}, ensure_ascii=False))
