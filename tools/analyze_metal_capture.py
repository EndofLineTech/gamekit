"""Summarize private stage-in traces and Apple's documented Metal HUD CSV.

Outputs counts/timing statistics, never raw shader reflection or shader IDs.
HUD timestamps identify emitted batches, NOT individual presentation times.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
from pathlib import Path
import re
import statistics
from typing import Any, Iterable, Optional


def _number(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError("Expected a finite nonnegative measurement")
    return float(value)


def parse_hud_line(line: str) -> Optional[dict[str, Any]]:
    if "metal-HUD:" not in line:
        return None
    prefix, payload = line.split("metal-HUD:", 1)
    timestamp = re.match(r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+", prefix)
    process = re.search(r"\[(\d+):[^\]]+\]", prefix)
    if timestamp is None or process is None:
        raise ValueError("HUD batch lacks timestamp or PID")
    fields = payload.strip().split(",")
    if len(fields) < 5 or (len(fields) - 3) % 2 or not fields[0].isdigit():
        raise ValueError("Incomplete HUD batch")
    values = [_number(float(value)) for value in fields[1:]]
    return {"reported_at": timestamp.group(), "pid": int(process.group(1)), "marker": int(fields[0]),
            "pairs": list(zip(values[2::2], values[3::2]))}


def _stats(values: list[float]) -> dict[str, Any]:
    ordered = sorted(values)
    return {"count": len(ordered), "min": min(ordered) if ordered else None,
            "median": statistics.median(ordered) if ordered else None,
            "p95": ordered[math.ceil(len(ordered) * 0.95) - 1] if ordered else None,
            "max": max(ordered) if ordered else None}


def analyze(records: list[dict[str, Any]], hud_lines: Iterable[str], *, pid: int) -> dict[str, Any]:
    calls = [r for r in records if r.get("pid") == pid and r.get("event") in {"public-stage-in", "d3dmetal-stage-in"}]
    if any(type(r.get("success")) is not bool for r in calls):
        raise ValueError("Stage-in success must be a JSON boolean")
    failed = [r for r in calls if not r["success"]]
    duration = [_number(r["durationMS"]) for r in failed if "durationMS" in r]
    times = [_number(r["unixTime"]) for r in failed if "unixTime" in r]
    ids = {r["reflection"]["ShaderID"] for r in failed if isinstance(r.get("reflection"), dict) and isinstance(r["reflection"].get("ShaderID"), str)}
    batches = []
    for line in hud_lines:
        if len(line) > 1048576:
            raise ValueError("Oversized log line")
        batch = parse_hud_line(line)
        if batch is not None and batch["pid"] == pid:
            batches.append(batch)
    intervals = [interval for batch in batches for interval, _ in batch["pairs"]]
    gpu = [gpu for batch in batches for _, gpu in batch["pairs"]]
    long_batches = []
    for batch in batches:
        long = [{"sample_index_in_batch": i, "interval_ms": interval, "gpu_ms": gpu}
                for i, (interval, gpu) in enumerate(batch["pairs"]) if interval >= 50]
        if long:
            long_batches.append({"reported_at": batch["reported_at"], "marker": batch["marker"], "long_intervals": long})
    def utc(seconds: float) -> str:
        return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat()
    return {"pid": pid, "trace": {
        "capture_present": bool(calls) or any(r.get("pid") == pid and r.get("event") == "trace-loaded" for r in records),
        "failed_calls_recorded": len(failed), "successful_calls_sampled": len(calls) - len(failed),
        "unique_failed_shader_ids": len(ids), "failed_call_ms": _stats(duration),
        "sum_failed_call_elapsed_ms": sum(duration) if duration else None,
        "first_failure_utc": utc(min(times)) if times else None,
        "last_failure_utc": utc(max(times)) if times else None,
        "failure_record_limit_reached": len(failed) >= 64,
    }, "hud": {"batches": len(batches), "timing_pairs": len(intervals),
        "interval_ms": _stats(intervals), "gpu_ms": _stats(gpu),
        "intervals_at_least_50ms": sum(v >= 50 for v in intervals),
        "intervals_at_least_100ms": sum(v >= 100 for v in intervals),
        "long_batches": long_batches,
        "scope": "Captured timing pairs; batch markers are not interpreted as unique frame IDs. Batch timestamps are reporting times in the input log's timezone. No exact frame/error overlap or causal claim is inferred."
    }}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, help="Optional stage-in trace; omit for a HUD-only run")
    parser.add_argument("--hud", required=True, type=Path)
    parser.add_argument("--pid", required=True, type=int)
    args = parser.parse_args()
    if args.pid <= 0:
        parser.error("PID must be positive")
    records = []
    if args.trace:
        with args.trace.open(encoding="utf-8") as stream:
            for line in stream:
                if len(line) > 1048576:
                    raise ValueError("Oversized trace record")
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError("Trace records must be objects")
                records.append(record)
    with args.hud.open(encoding="utf-8") as stream:
        result = analyze(records, stream, pid=args.pid)
    print(json.dumps(result, indent=2, sort_keys=True, allow_nan=False))


if __name__ == "__main__":
    main()
