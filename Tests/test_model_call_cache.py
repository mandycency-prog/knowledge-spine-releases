import unittest
from check_discourse_real import call_key


class ModelCallCacheTest(unittest.TestCase):
    def test_property_order_is_not_lost_in_cache_key(self):
        first = {"type": "object", "properties": {"verdict": {"type": "string"}, "reason": {"type": "string"}}}
        last = dict(first, properties=dict(reversed(list(first["properties"].items()))))
        self.assertEqual(first, last)
        self.assertNotEqual(call_key("system", "source", first, {}), call_key("system", "source", last, {}))

    def test_sampling_order_is_ignored_but_sampling_values_are_not(self):
        self.assertEqual(call_key("s", "p", {}, {"temperature": 0, "seed": 1}),
                         call_key("s", "p", {}, {"seed": 1, "temperature": 0}))
        self.assertNotEqual(call_key("s", "p", {}, {"temperature": 0}),
                            call_key("s", "p", {}, {"temperature": 1}))


if __name__ == "__main__":
    unittest.main()
