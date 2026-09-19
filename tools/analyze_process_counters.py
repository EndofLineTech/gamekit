"""Associate HUD reporting batches with coarse, identity-pinned CPU/IO windows.

These are context windows, not exact per-frame attribution or causal findings.
Schema-less early captures are rejected: rusage CPU times are Mach ticks, not ns.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import math
from pathlib import Path
import re

if __package__:
    from .analyze_metal_capture import parse_hud_line
else:
    from analyze_metal_capture import parse_hud_line


def summarize_window(records: list[dict], pid: int, start: float, end: float):
    headers = [r for r in records if r.get("event") == "start" and r.get("pid") == pid]
    if len(headers) != 1 or headers[0].get("schemaVersion") != 1:
        raise ValueError("Require one schema-1 timebase header for this PID")
    header = headers[0]
    numer, denom = header.get("timebase_numer"), header.get("timebase_denom")
    if type(numer) is not int or type(denom) is not int or min(numer, denom) <= 0:
        raise ValueError("Invalid Mach timebase")
    if not math.isfinite(start) or not math.isfinite(end) or end <= start:
        raise ValueError("Invalid time window")
    samples = [r for r in records if r.get("event") == "sample" and r.get("pid") == pid and start <= r["unixTime"] <= end]
    if len(samples) < 2:
        return None
    fields = ["user_ticks", "system_ticks", "disk_read_bytes", "disk_write_bytes", "pageins"]
    for sample in samples:
        if any(type(sample.get(key)) is not int or sample[key] < 0 for key in fields):
            raise ValueError("Invalid cumulative counter")
    for previous, current in zip(samples, samples[1:]):
        if current["unixTime"] <= previous["unixTime"] or any(current[key] < previous[key] for key in fields):
            raise ValueError("Non-monotonic counter capture")
    first, last = samples[0], samples[-1]
    elapsed = last["unixTime"] - first["unixTime"]
    delta = {key: last[key] - first[key] for key in fields}
    cpu = (delta["user_ticks"] + delta["system_ticks"]) * numer / denom / 1e9
    footprints = [sample.get("footprint_bytes") for sample in samples]
    if any(value is not None and (type(value) is not int or value < 0) for value in footprints):
        raise ValueError("Invalid memory footprint")
    peak = max(footprints) if all(value is not None for value in footprints) else None
    return {"samples": len(samples), "covered_seconds": elapsed, "coverage_fraction": elapsed / (end - start),
            "cpu_seconds": cpu, "cpu_core_equivalents": cpu / elapsed,
            "disk_read_bytes": delta["disk_read_bytes"], "disk_write_bytes": delta["disk_write_bytes"], "pageins": delta["pageins"],
            "peak_footprint_bytes": peak}


def load_records(path: Path, diagnostic_record: bool = False) -> list[dict]:
    with path.open("rb") as stream:
        data = stream.read(2 * 1024 * 1024 + 1)
    if len(data) > 2 * 1024 * 1024:
        raise ValueError("Capture exceeds the supported size")
    if diagnostic_record:
        document = json.loads(data)
        if document.get("schemaVersion") != 1 or document.get("stage") != "performanceCapture":
            raise ValueError("Expected a local performanceCapture diagnostic record")
        data = base64.b64decode(document["stdout"], validate=True)
    return [json.loads(line) for line in data.splitlines() if line.strip()]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--counters", type=Path)
    inputs.add_argument("--diagnostic-record", type=Path, help="App's private local performanceCapture record (not summary export)")
    parser.add_argument("--hud", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--utc-offset", help="Explicit HUD log offset, e.g. --utc-offset=-05:00")
    parser.add_argument("--threshold-ms", type=float, default=100)
    args = parser.parse_args()
    if (args.pid is not None and args.pid <= 0) or (args.hud and not re.fullmatch(r"[+-]\d\d:\d\d", args.utc_offset or "")) or not math.isfinite(args.threshold_ms) or args.threshold_ms <= 0:
        parser.error("Invalid PID, timezone offset or threshold")
    records = load_records(args.diagnostic_record or args.counters, args.diagnostic_record is not None)
    if args.pid is None:
        pids = {r.get("pid") for r in records if r.get("event") == "start"}
        if len(pids) != 1:
            parser.error("Specify a PID or provide a capture with exactly one process header")
        args.pid = pids.pop()
        if type(args.pid) is not int or args.pid <= 0:
            parser.error("Invalid capture PID")
    if not args.hud:
        samples = [r for r in records if r.get("event") == "sample" and r.get("pid") == args.pid]
        summary = summarize_window(records, args.pid, samples[0]["unixTime"], samples[-1]["unixTime"]) if len(samples) >= 2 else None
        print(json.dumps({"pid": args.pid, "context": "Whole captured process window; not frame timing or causal attribution.", "counters": summary}, indent=2, allow_nan=False))
        return
    windows = []
    with args.hud.open() as stream:
        for line in stream:
            batch = parse_hud_line(line)
            if batch is None or batch["pid"] != args.pid:
                continue
            maximum = max(value for value, _ in batch["pairs"])
            if maximum < args.threshold_ms:
                continue
            reported = dt.datetime.fromisoformat(batch["reported_at"] + args.utc_offset)
            stamp = reported.timestamp()
            windows.append({"hud_reported_at_utc": reported.astimezone(dt.timezone.utc).isoformat(),
                            "max_interval_ms": maximum, "counter_window": summarize_window(records, args.pid, stamp - 2, stamp + 0.25)})
    print(json.dumps({"pid": args.pid, "context": "Counter windows cover 2 seconds before through 0.25 seconds after HUD batch emission. Not exact frame timestamps or causal attribution. Cached reads/decompression can occur without disk counter growth.",
                      "hitch_batches": windows}, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
