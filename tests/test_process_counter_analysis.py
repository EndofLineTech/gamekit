import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from tools.analyze_process_counters import load_records, summarize_window


class ProcessCounterAnalysisTests(unittest.TestCase):
    def test_app_record_decoding_and_counter_only_cli(self):
        records = [{"event": "start", "schemaVersion": 1, "pid": 42, "timebase_numer": 125, "timebase_denom": 3},
                   {"event": "sample", "pid": 42, "unixTime": 100, "user_ticks": 0, "system_ticks": 0, "disk_read_bytes": 0, "disk_write_bytes": 0, "pageins": 0, "footprint_bytes": 1024},
                   {"event": "sample", "pid": 42, "unixTime": 102, "user_ticks": 48000000, "system_ticks": 0, "disk_read_bytes": 4096, "disk_write_bytes": 0, "pageins": 1, "footprint_bytes": 2048}]
        encoded = base64.b64encode("\n".join(json.dumps(row) for row in records).encode()).decode()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "operation.json"
            path.write_text(json.dumps({"schemaVersion": 1, "stage": "performanceCapture", "stdout": encoded}))
            self.assertEqual(load_records(path, True), records)
            tool = Path(__file__).resolve().parents[1] / "tools/analyze_process_counters.py"
            result = subprocess.run([sys.executable, str(tool), "--diagnostic-record", str(path)], check=True, capture_output=True, text=True)
            summary = json.loads(result.stdout)["counters"]
            self.assertEqual(summary["cpu_seconds"], 2)
            self.assertEqual(summary["peak_footprint_bytes"], 2048)
            path.write_text(json.dumps({"schemaVersion": 1, "stage": "launch", "stdout": encoded}))
            with self.assertRaises(ValueError):
                load_records(path, True)
    def test_timebase_conversion_and_disk_deltas(self):
        records = [{"event": "start", "schemaVersion": 1, "pid": 42, "timebase_numer": 125, "timebase_denom": 3},
                   {"event": "sample", "pid": 42, "unixTime": 100, "user_ticks": 0, "system_ticks": 0, "disk_read_bytes": 100, "disk_write_bytes": 10, "pageins": 2},
                   {"event": "sample", "pid": 42, "unixTime": 102, "user_ticks": 48000000, "system_ticks": 0, "disk_read_bytes": 4194404, "disk_write_bytes": 10, "pageins": 5}]
        result = summarize_window(records, 42, 100, 102)
        self.assertEqual(result["cpu_core_equivalents"], 1)
        self.assertEqual(result["disk_read_bytes"], 4194304)
        self.assertEqual(result["pageins"], 3)

    def test_legacy_mislabeled_data_missing_coverage_and_counter_reversal_fail(self):
        with self.assertRaises(ValueError):
            summarize_window([{"event": "sample", "pid": 42, "user_ns": 1}], 42, 100, 102)
        header = {"event": "start", "schemaVersion": 1, "pid": 42, "timebase_numer": 125, "timebase_denom": 3}
        self.assertIsNone(summarize_window([header], 42, 100, 102))
        first = {"event": "sample", "pid": 42, "unixTime": 100, "user_ticks": 2, "system_ticks": 0, "disk_read_bytes": 0, "disk_write_bytes": 0, "pageins": 0}
        with self.assertRaises(ValueError):
            summarize_window([header, first, dict(first, unixTime=101, user_ticks=1)], 42, 100, 101)


if __name__ == "__main__":
    unittest.main()
