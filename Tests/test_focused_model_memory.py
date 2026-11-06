import sys
import unittest
from pathlib import Path
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Backend"))
from local_pipeline import RecoverableFocusedModel


class FocusedModelMemoryTests(unittest.TestCase):
    def test_failed_load_releases_lease_and_normal_model_does_not_retry(self):
        lease = Mock()
        def failed(_):
            raise RuntimeError("load failed")
        with self.assertRaises(RuntimeError):
            RecoverableFocusedModel(failed, lease=lease)
        lease.close.assert_called_once()
        backend = Mock()
        lease = Mock()
        model = RecoverableFocusedModel(lambda _: backend, lease=lease, gpu_layers=-1, recovery_layers=None)
        self.assertFalse(model.recover_after_decode_failure())
        lease.close.assert_not_called()
        model.close()
        backend.close.assert_called_once()
        lease.close.assert_called_once()

    def test_recovery_closes_failed_backend_before_allocating_replacement(self):
        first, second = Mock(), Mock()
        events = []
        first.close.side_effect = lambda: events.append("closed")
        def factory(layers):
            events.append(layers)
            return first if layers == -1 else second
        model = RecoverableFocusedModel(factory)
        self.assertTrue(model.recover_after_decode_failure())
        self.assertEqual(events, [-1, "closed", 24])
        self.assertFalse(model.recover_after_decode_failure())
        model.close()
        second.close.assert_called_once()
        model.close()
        second.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
