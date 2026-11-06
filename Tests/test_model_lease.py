import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BACKEND = Path(__file__).resolve().parents[1] / "Backend"
sys.path.insert(0, str(BACKEND))
from model_lease import ModelLease


class ModelLeaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.directory = self.root / "locks"

    def tearDown(self):
        self.temp.cleanup()

    def child(self):
        code = ("import sys,time;sys.path.insert(0,sys.argv[1]);from model_lease import ModelLease;"
                "lease=ModelLease('other-model',lock_directory=sys.argv[2]).acquire();"
                "print('locked',flush=True);sys.stdin.readline();lease.close()")
        child = subprocess.Popen([sys.executable, "-c", code, str(BACKEND), str(self.directory)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop_child, child)
        self.assertEqual(child.stdout.readline().strip(), "locked")
        return child

    @staticmethod
    def stop_child(child):
        if child.poll() is None:
            child.kill()
        child.wait(timeout=5)
        for pipe in (child.stdin, child.stdout, child.stderr):
            pipe.close()

    def test_two_processes_different_models_share_one_lock_and_release(self):
        child = self.child()
        messages = []
        lease = ModelLease("first-model", timeout=0.2, progress=messages.append, lock_directory=self.directory)
        with self.assertRaises(TimeoutError):
            lease.acquire()
        self.assertEqual(len(messages), 1)
        child.stdin.write("done\n")
        child.stdin.flush()
        child.wait(timeout=5)
        lease.acquire()
        lease.close()
        lease.close()
        self.assertEqual((self.directory / "all-models.lock").stat().st_mode & 0o777, 0o600)

    def test_process_death_releases_kernel_lock(self):
        child = self.child()
        child.kill()
        child.wait(timeout=5)
        with ModelLease("model", timeout=0.2, lock_directory=self.directory):
            pass

    def test_normalized_model_path_and_symlink_have_same_digest(self):
        model = self.root / "model.gguf"
        model.touch()
        alias = self.root / "alias.gguf"
        alias.symlink_to(model)
        self.assertEqual(ModelLease(model).model_digest, ModelLease(alias).model_digest)

    def test_rejects_symlink_lock_and_directory(self):
        self.directory.mkdir(mode=0o700)
        target = self.root / "unrelated"
        target.touch(mode=0o600)
        (self.directory / "all-models.lock").symlink_to(target)
        with self.assertRaises(OSError):
            ModelLease("model", lock_directory=self.directory).acquire()
        alias = self.root / "linked-directory"
        alias.symlink_to(self.directory)
        with self.assertRaises(PermissionError):
            ModelLease("model", lock_directory=alias).acquire()

    def test_rejects_world_readable_lock(self):
        self.directory.mkdir(mode=0o700)
        (self.directory / "all-models.lock").touch(mode=0o644)
        with self.assertRaises(PermissionError):
            ModelLease("model", lock_directory=self.directory).acquire()


if __name__ == "__main__":
    unittest.main()
