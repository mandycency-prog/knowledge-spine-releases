import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class PackagedQuoteBackendTest(unittest.TestCase):
    def test_packaging_lists_module_and_isolated_pipeline_calls_it(self):
        root = Path(__file__).resolve().parents[1]
        script = (root / "scripts/package_app.sh").read_text()
        modules = ("local_pipeline.py", "quote_evidence.py", "audio_context.py", "apple_speech.py",
                   "source_bound_map.py", "stage_synthesis.py", "branch_expansion.py", "transcript_proofreader.py")
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "Backend"
            target.mkdir()
            for name in modules:
                self.assertIn(f'cp "$project_dir/Backend/{name}" "$app_dir/Contents/Resources/Backend/{name}"', script)
                shutil.copy2(root / "Backend" / name, target / name)
            code = '''
import sys
sys.path.insert(0, sys.argv[1])
import local_pipeline as p
import source_bound_map, stage_synthesis, branch_expansion
assert source_bound_map.__file__.startswith(sys.argv[1])
assert stage_synthesis.__file__.startswith(sys.argv[1])
assert branch_expansion.__file__.startswith(sys.argv[1])
def completion(llm, system, prompt, schema, **kwargs):
    if "evidence" in schema["properties"]:
        return {"evidence": [{"claimIndex": 0, "quotes": ["方法只适用于条件稳定时。"]}]}
    return {"verdict": "supported", "claimQuote": "方法受到条件限制", "evidenceQuotes": ["方法只适用于条件稳定时。"], "assumptions": [], "reason": "原文限制适用条件"}
p.structured_completion = completion
n = {"summary": "方法受到条件限制", "coveredSourceSpanIDs": ["source"]}
p.verify_discourse_semantics(None, [n], [{"sourceSpanIDs": ["source"], "sourceText": "方法只适用于条件稳定时。"}], [[0]], transcript_spans=[{"id": "source", "sequence": 7, "originalText": "方法只适用于条件稳定时。"}])
assert n["sourceSpanIDs"] == ["source"]
assert p.quote_evidence.__file__.startswith(sys.argv[1])
print("isolated-packaged-quote-ok")
'''
            result = subprocess.run([sys.executable, "-I", "-c", code, str(target)], cwd=temp,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("isolated-packaged-quote-ok", result.stdout)
            self.assertIn("QUOTE_AUDIT", result.stderr)
