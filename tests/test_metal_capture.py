import unittest

from tools.analyze_metal_capture import analyze, parse_hud_line


class MetalCaptureTests(unittest.TestCase):
    def test_hud_pairs_do_not_include_memory_fields_or_invent_frame_times(self):
        batch = parse_hud_line("2026-09-18 13:24:29.729 game[42:99] metal-HUD: 95,1800,3450,8.33,7.1,175,9.46")
        self.assertEqual(batch["pid"], 42)
        self.assertEqual(batch["marker"], 95)
        self.assertEqual(batch["pairs"], [(8.33, 7.1), (175.0, 9.46)])
        self.assertEqual(batch["reported_at"], "2026-09-18 13:24:29.729")

    def test_malformed_nonfinite_and_unscoped_hud_data_is_rejected(self):
        for payload in ["1,2,3,4", "1,2,3,nan,0", "1,2,3,-1,0", "1,2,3,inf,0"]:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                parse_hud_line("2026-09-18 00:00:00.000 game[42:99] metal-HUD: " + payload)
        with self.assertRaises(ValueError):
            parse_hud_line("metal-HUD: 1,2,3,8,4")
        with self.assertRaises(ValueError):
            parse_hud_line("2026-09-18 00:00:00.000 game[42:99] metal-HUD: 1,2,3<private>")
        self.assertIsNone(parse_hud_line("unrelated private log text"))

    def test_analysis_filters_pid_keeps_failure_and_sample_scopes_separate(self):
        records = [
            {"event": "trace-loaded", "pid": 42},
            {"event": "d3dmetal-stage-in", "pid": 42, "success": False, "durationMS": 0.2, "unixTime": 100, "reflection": {"ShaderID": "private-shader", "ShaderType": "Vertex"}},
            {"event": "d3dmetal-stage-in", "pid": 42, "success": False, "durationMS": 3.5, "unixTime": 101, "reflection": {"ShaderID": "private-shader", "ShaderType": "Vertex"}},
            {"event": "d3dmetal-stage-in", "pid": 42, "success": True, "durationMS": 7, "unixTime": 102, "reflection": {}},
        ]
        hud = ["2026-09-18 00:00:00.000 game[42:99] metal-HUD: 2,1,2,8,4,175,9",
               "2026-09-18 00:00:01.000 other[77:99] metal-HUD: 1,1,2,999,999"]
        result = analyze(records, hud, pid=42)
        self.assertEqual(result["trace"]["failed_calls_recorded"], 2)
        self.assertEqual(result["trace"]["unique_failed_shader_ids"], 1)
        self.assertEqual(result["trace"]["failed_call_ms"]["max"], 3.5)
        self.assertEqual(result["hud"]["timing_pairs"], 2)
        self.assertEqual(result["hud"]["interval_ms"]["max"], 175)
        self.assertEqual(result["hud"]["intervals_at_least_100ms"], 1)
        self.assertNotIn("private-shader", str(result))

    def test_missing_data_is_not_reported_as_zero_latency_or_a_pass(self):
        result = analyze([{"event": "trace-loaded", "pid": 42}], [], pid=42)
        self.assertIsNone(result["trace"]["failed_call_ms"]["max"])
        self.assertIsNone(result["hud"]["interval_ms"]["p95"])
        self.assertEqual(result["hud"]["timing_pairs"], 0)
        self.assertFalse(analyze([], [], pid=42)["trace"]["capture_present"])


if __name__ == "__main__":
    unittest.main()
