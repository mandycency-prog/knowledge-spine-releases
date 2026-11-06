"""Run a real isolated ASR check; reference text is never sent to the model."""
import argparse
import json
import re
import resource
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--manifest", required=True)
parser.add_argument("--reference", required=True)
parser.add_argument("--output-directory", required=True)
parser.add_argument("--baseline-result")
parser.add_argument("--apple-helper")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = Path(args.output_directory).resolve()
output.mkdir(parents=True, exist_ok=False)
manifest = json.loads(Path(args.manifest).read_text())
manifest["asr_checkpoint_path"] = str(output / "checkpoint.json")
manifest.pop("asr_window_mode", None)
if args.apple_helper:
    manifest["apple_speech_path"] = str(Path(args.apple_helper).resolve())
(output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False))
started = time.monotonic()
with (output / "run.log").open("w") as log:
    subprocess.run([sys.executable, str(root / "Backend/local_pipeline.py"), "--asr-only",
                    "--manifest", str(output / "manifest.json"), "--output", str(output / "result.json")],
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
elapsed = time.monotonic() - started
sys.path.insert(0, str(root / "Backend"))
from local_pipeline import comparison_text

def normalize(text):
    return re.sub(r"[^\w]", "", comparison_text(text)).lower()

def error_rate(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, a in enumerate(reference, 1):
        row = [i]
        for j, b in enumerate(hypothesis, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = row
    return previous[-1] / max(1, len(reference))

reference = normalize(Path(args.reference).read_text())
def inspect(path):
    result = json.loads(Path(path).read_text())
    text = "".join(span["originalText"] for span in result["spans"])
    return {"characterErrorRate": error_rate(reference, normalize(text)), "text": comparison_text(text)}

report = {"elapsedSeconds": elapsed, "peakChildRSSBytes": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
          "current": inspect(output / "result.json")}
if args.baseline_result:
    report["baseline"] = inspect(args.baseline_result)
(output / "comparison.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False, indent=2))
