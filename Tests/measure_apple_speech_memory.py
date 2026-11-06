"""Sample helper + named Apple speech-service RSS; not total unified memory."""
import json
import subprocess
import sys
import time

helper, audio = sys.argv[1:]
service_names = ("localspeechrecognition", "corespeechd", "com.apple.siri.embeddedspeech")
def snapshot():
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid,rss,comm"], text=True).splitlines()[1:]
    services, helpers = 0, 0
    for row in rows:
        parts = row.strip().split(None, 2)
        if len(parts) != 3:
            continue
        size, name = int(parts[1]) * 1024, parts[2]
        if any(token in name for token in service_names):
            services += size
        elif "KnowledgeSpineAppleSpeech" in name:
            helpers += size
    return {"speechServicesRSSBytes": services, "helperRSSBytes": helpers}

baseline = snapshot()
peaks = dict(baseline)
statuses = []
started = time.monotonic()
for _ in range(3):
    child = subprocess.Popen([helper, "--transcribe", audio], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        while child.poll() is None:
            if time.monotonic() - started > 120:
                raise TimeoutError("memory check exceeded two minutes")
            for key, size in snapshot().items():
                peaks[key] = max(peaks[key], size)
            time.sleep(0.05)
        statuses.append(child.returncode)
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=5)
print(json.dumps({"baseline": baseline, "observedPeaks": peaks, "exitStatuses": statuses,
                  "seconds": time.monotonic() - started,
                  "limitation": "Sampled RSS includes shared services and may double-count shared pages; excludes compressed/GPU allocations and other apps. Not an end-to-end total-memory guarantee."}, indent=2))
assert statuses == [0, 0, 0]
