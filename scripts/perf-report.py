#!/usr/bin/env python3
"""W44-prep: turns the isolated performance run's raw files into one table (p50/p95/worst, failed operations, stalls, CPU, footprint).

  perf-report.py --dir <perf dir> [--out report.md] [--json result.json]
  perf-report.py --self-test

Reads, inside <perf dir>, whichever of these exist:
  performance-intervals.jsonl   one JSON object per finished signpost interval or main-thread stall, written by the app (Debug, isolated launches only)
  benchmarks.jsonl              one JSON object per headless model measurement (Packages/NativeMusic/Tests/PerformanceTests)
  process-samples.jsonl         one JSON object per sample from scripts/perf-sample.py (CPU and physical footprint over the app and its helpers)

Every number is INDICATIVE (optimized Debug, isolated, synthetic data). Failed operations are reported on their own line and are NEVER removed
from the percentile population's count (PERF01); a percentile is computed over the completed operations and the failed ones are printed beside it.
"""
import argparse, json, math, os, sys, tempfile
from collections import defaultdict


def percentile(values, p):
    """Nearest-rank percentile (the rank is ceil(p*n)); NaN for an empty list."""
    if not values:
        return float("nan")
    ordered = sorted(values)
    rank = max(1, math.ceil(p * len(ordered)))
    return ordered[min(len(ordered), rank) - 1]


def read_jsonl(path):
    rows, bad = [], 0
    if not os.path.exists(path):
        return rows, bad
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1
    return rows, bad


def tag_sessions(rows):
    """The app writes `{"session": {"pid", "test"}}` first in each launch's log; the records after it belong to that test. Returns (records with a `test`, pid -> test)."""
    current, tagged, pids = "unattributed", [], {}
    for row in rows:
        session = row.get("session")
        if isinstance(session, dict):
            current = str(session.get("test", "unattributed"))
            if isinstance(session.get("pid"), int):
                pids[session["pid"]] = current
            continue
        tagged.append(dict(row, test=current))
    return tagged, pids


def summarize_intervals(rows):
    """Groups finished intervals by (test, interval, label). Stalls are the records with no interval, counted per test."""
    groups, stalls_by_test = defaultdict(lambda: {"ok": [], "failed": 0}), defaultdict(list)
    for row in rows:
        interval, label, ms = row.get("interval"), row.get("label"), row.get("durationMilliseconds")
        if not isinstance(ms, (int, float)) or ms < 0 or ms != ms:
            continue
        if interval is None:
            stalls_by_test[row.get("test", "unattributed")].append(ms)
            continue
        key = (row.get("test", "unattributed"), interval, label or "")
        if row.get("failed"):
            groups[key]["failed"] += 1
        else:
            groups[key]["ok"].append(ms)
    result = []
    for (test, interval, label), data in sorted(groups.items()):
        ok = data["ok"]
        result.append({"test": test, "interval": interval, "label": label, "completed": len(ok), "failed": data["failed"],
                       "p50": percentile(ok, 0.5), "p95": percentile(ok, 0.95), "worst": max(ok) if ok else float("nan")})
    stall = {test: {"over16_7ms": len(v), "over50ms": sum(1 for s in v if s >= 50), "over100ms": sum(1 for s in v if s >= 100), "worstMs": max(v) if v else 0.0} for test, v in sorted(stalls_by_test.items())}
    return result, stall


def summarize_benchmarks(rows):
    out = []
    for row in rows:
        samples = [s for s in row.get("samples", []) if isinstance(s, (int, float))]
        out.append({"name": row.get("name", "?"), "n": len(samples), "p50": percentile(samples, 0.5), "p95": percentile(samples, 0.95),
                    "worst": max(samples) if samples else float("nan"), "notes": row.get("notes")})
    return out


def summarize_processes_by_test(rows, pids):
    """One summary per scripted test: a sample belongs to the test whose app process it contains (`pids` comes from the sessions)."""
    groups = defaultdict(list)
    for row in rows:
        test = next((pids[p["pid"]] for p in row.get("processes", []) if p.get("pid") in pids), "unattributed")
        groups[test].append(row)
    return {test: summarize_processes(group) for test, group in sorted(groups.items())}


def summarize_processes(rows):
    """CPU is the sum over the app and its helpers (100% = one logical core); footprint is the sum of physical footprints."""
    cpu = [r["cpuPercentTotal"] for r in rows if isinstance(r.get("cpuPercentTotal"), (int, float))]
    foot = [r["footprintMiBTotal"] for r in rows if isinstance(r.get("footprintMiBTotal"), (int, float))]
    helpers = sorted({p.get("name", "?") for r in rows for p in r.get("processes", [])})
    return {"samples": len(rows), "cpuMean": sum(cpu) / len(cpu) if cpu else float("nan"), "cpuP95": percentile(cpu, 0.95), "cpuMax": max(cpu) if cpu else float("nan"),
            "footprintMiBMean": sum(foot) / len(foot) if foot else float("nan"), "footprintMiBMax": max(foot) if foot else float("nan"),
            "footprintMiBFirst": foot[0] if foot else float("nan"), "footprintMiBLast": foot[-1] if foot else float("nan"), "processNames": helpers}


def fmt(x):
    return "n/a" if x is None or (isinstance(x, float) and x != x) else f"{x:.2f}"


def render(intervals, stall, benchmarks, procs, parse_errors):
    lines = ["# Indicative performance run (optimized Debug, isolated, synthetic data)", "",
             "Not W44 results: the official numbers come from Release builds on the reference Mac (`Docs/Performance-Runbook.md`).", ""]
    if intervals:
        lines += ["## Signpost intervals (app, from `performance-intervals.jsonl`)", "", "| test | interval | label | completed | failed | p50 ms | p95 ms | worst ms |", "|---|---|---|---:|---:|---:|---:|---:|"]
        lines += [f"| {r['test']} | {r['interval']} | {r['label']} | {r['completed']} | {r['failed']} | {fmt(r['p50'])} | {fmt(r['p95'])} | {fmt(r['worst'])} |" for r in intervals]
        lines.append("")
    if stall:
        lines += ["## Main-thread stalls (run-loop iterations longer than one 60 Hz frame, 16.7 ms)", "", "| test | over 16.7 ms | over 50 ms | over 100 ms | worst ms |", "|---|---:|---:|---:|---:|"]
        lines += [f"| {test} | {v['over16_7ms']} | {v['over50ms']} | {v['over100ms']} | {fmt(v['worstMs'])} |" for test, v in stall.items()]
        lines.append("")
    if benchmarks:
        lines += ["## Headless model measurements", "", "| measurement | n | p50 ms | p95 ms | worst ms | notes |", "|---|---:|---:|---:|---:|---|"]
        lines += [f"| {r['name']} | {r['n']} | {fmt(r['p50'])} | {fmt(r['p95'])} | {fmt(r['worst'])} | {r['notes'] or ''} |" for r in benchmarks]
        lines.append("")
    if procs:
        lines += ["## Processes (app plus descendants), per scripted test", "", "| test | samples | CPU mean % | CPU p95 % | CPU max % | footprint first MiB | footprint mean MiB | footprint max MiB | footprint last MiB |", "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for test, p in procs.items():
            lines.append(f"| {test} | {p['samples']} | {fmt(p['cpuMean'])} | {fmt(p['cpuP95'])} | {fmt(p['cpuMax'])} | {fmt(p['footprintMiBFirst'])} | {fmt(p['footprintMiBMean'])} | {fmt(p['footprintMiBMax'])} | {fmt(p['footprintMiBLast'])} |")
        lines += ["", "CPU is the sum over the app and its descendant processes (100% = one fully used logical core); footprint is the sum of physical footprints. XPC helpers started through launchd are not descendants (see the runbook).", ""]
    if parse_errors:
        lines += [f"Unreadable lines skipped: {parse_errors}", ""]
    if not (intervals or benchmarks or procs):
        lines += ["No raw data found in the directory.", ""]
    return "\n".join(lines)


def clean(value):
    """NaN is not JSON: an empty percentile is written as null (json.dump's `default=` never sees floats)."""
    if isinstance(value, float) and value != value:
        return None
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean(v) for v in value]
    return value


def build(directory):
    interval_rows, bad1 = read_jsonl(os.path.join(directory, "performance-intervals.jsonl"))
    bench_rows, bad2 = read_jsonl(os.path.join(directory, "benchmarks.jsonl"))
    proc_rows, bad3 = read_jsonl(os.path.join(directory, "process-samples.jsonl"))
    tagged, pids = tag_sessions(interval_rows)
    intervals, stall = summarize_intervals(tagged)
    benchmarks, procs = summarize_benchmarks(bench_rows), summarize_processes_by_test(proc_rows, pids)
    return {"intervals": intervals, "mainThreadStalls": stall, "benchmarks": benchmarks, "processes": procs, "unreadableLines": bad1 + bad2 + bad3}


def self_test():
    assert percentile([1, 2, 3, 4], 0.5) == 2 and percentile([1, 2, 3, 4], 0.95) == 4 and percentile([5], 0.95) == 5 and percentile([], 0.5) != percentile([], 0.5)
    ordered = list(range(1, 101))
    assert percentile(ordered, 0.5) == 50 and percentile(ordered, 0.95) == 95 and percentile(ordered, 1.0) == 100
    with tempfile.TemporaryDirectory() as directory:
        with open(os.path.join(directory, "performance-intervals.jsonl"), "w") as handle:
            handle.write(json.dumps({"session": {"pid": 77, "test": "testX"}}) + "\n")
            for ms in (10, 20, 30):
                handle.write(json.dumps({"interval": "navigation", "label": "library", "durationMilliseconds": ms, "failed": False}) + "\n")
            handle.write(json.dumps({"interval": "navigation", "label": "library", "durationMilliseconds": 9999, "failed": True}) + "\n")
            handle.write(json.dumps({"interval": None, "label": "mainStall", "durationMilliseconds": 120, "failed": False}) + "\n")
            handle.write("not json\n")
        result = build(directory)
        row = result["intervals"][0]
        # The failed operation is counted on its own and its 9999 ms never reaches the percentile of the completed ones.
        assert row["completed"] == 3 and row["failed"] == 1 and row["p50"] == 20 and row["worst"] == 30, row
        assert row["test"] == "testX" and result["mainThreadStalls"]["testX"]["over100ms"] == 1 and result["unreadableLines"] == 1
        assert summarize_processes_by_test([{"processes": [{"pid": 77}], "cpuPercentTotal": 5, "footprintMiBTotal": 100}], {77: "testX"})["testX"]["footprintMiBMax"] == 100
        assert "failed" in render(result["intervals"], result["mainThreadStalls"], [], {}, 0)
    assert clean({"a": float("nan"), "b": [1.0, float("nan")]}) == {"a": None, "b": [1.0, None]}
    print("perf-report self-test: ok")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir")
    parser.add_argument("--out")
    parser.add_argument("--json")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.dir:
        parser.error("--dir is required")
    result = build(args.dir)
    text = render(result["intervals"], result["mainThreadStalls"], result["benchmarks"], result["processes"], result["unreadableLines"])
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        print(text)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(clean(result), handle, indent=2, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
