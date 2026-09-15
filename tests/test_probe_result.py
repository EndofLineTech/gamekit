import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "runtime_probe", Path(__file__).parents[1] / "scripts/run_runtime_probe.py"
)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class ProbeResultTests(unittest.TestCase):
    def test_zero_exit_and_pass_text_do_not_hide_worker_crash(self):
        text = "PASS probe\nwine: Unhandled page fault on read access\n"
        self.assertFalse(probe.assess(0, text, ["PASS probe"])["ok"])

    def test_requires_completed_probe_and_expected_image(self):
        self.assertFalse(probe.assess(0, "PASS probe", ["PASS probe", "/correct/D3DMetal"])["ok"])
        self.assertFalse(probe.assess(1, "PASS probe\n/correct/D3DMetal",
                                      ["PASS probe", "/correct/D3DMetal"])["ok"])
        self.assertTrue(probe.assess(0, "PASS probe\n/correct/D3DMetal",
                                     ["PASS probe", "/correct/D3DMetal"])["ok"])

    def test_missing_completion_or_failure_message_is_not_success(self):
        self.assertFalse(probe.assess(0, "process started", ["PASS probe"])["ok"])
        self.assertFalse(probe.assess(0, "PASS probe\nFAIL another check", ["PASS probe"])["ok"])


if __name__ == "__main__":
    unittest.main()
