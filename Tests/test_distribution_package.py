"""Synthetic packaging checks; no private database, models, signing or network."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
MODULE=Path(__file__).resolve().parents[1]/'scripts/package_distribution.py'
spec=importlib.util.spec_from_file_location('distribution_package',MODULE)
package=importlib.util.module_from_spec(spec);spec.loader.exec_module(package)
class DistributionPackageTests(unittest.TestCase):
 def test_fixed_backend_manifest_matches_imported_runtime_modules(self):
  root=MODULE.parents[1]/'Backend'
  self.assertEqual(set(package.BACKEND),{p.name for p in root.glob('*.py')})
  self.assertNotIn('database.json',package.BACKEND)
 def test_streaming_hash_detects_changed_payload(self):
  with tempfile.TemporaryDirectory() as directory:
   p=Path(directory)/'synthetic';p.write_bytes(b'synthetic payload')
   first=package.sha(p);p.write_bytes(b'different payload')
   self.assertNotEqual(first,package.sha(p))
if __name__=='__main__':unittest.main()
