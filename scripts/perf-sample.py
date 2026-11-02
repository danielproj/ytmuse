#!/usr/bin/env python3
"""W44-prep: samples CPU and physical footprint of the isolated app and its helpers (PERF02, PERF03). Read-only: it never signals, stops or changes a process.

  perf-sample.py --app-path-prefix <dir> --out <file.jsonl> --stop-file <file> [--interval 2] [--wait-seconds 120]

The app is found by its executable path: a process whose command starts with `--app-path-prefix` (this worktree's own build products). Its helpers are its
descendants (XPC services started by the app through launchd are NOT descendants; the isolated performance scenarios start no hidden web player, and any
helper that is a descendant is included and named). CPU is the sum of `ps` %CPU over those processes (100% = one fully used logical core); memory is the
sum of `footprint` physical footprints. Sampling ends when `--stop-file` appears or the app has gone for good.
"""
import argparse, json, os, subprocess, sys, time


def processes():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,pcpu=,command="], capture_output=True, text=True, check=False).stdout
    table = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        try:
            table[int(parts[0])] = {"pid": int(parts[0]), "ppid": int(parts[1]), "cpu": float(parts[2]), "command": parts[3]}
        except ValueError:
            continue
    return table


def find_app(table, prefix):
    return sorted(pid for pid, p in table.items() if p["command"].startswith(prefix))


def descendants(table, roots):
    found, frontier = set(roots), list(roots)
    while frontier:
        parent = frontier.pop()
        for pid, p in table.items():
            if p["ppid"] == parent and pid not in found:
                found.add(pid); frontier.append(pid)
    return sorted(found)


def footprints(pids):
    """Physical footprint in bytes per pid, from `footprint --json`; a process that cannot be read is reported with None, never guessed."""
    result = {pid: None for pid in pids}
    if not pids:
        return result
    path = f"/tmp/ytmuse-perf-footprint-{os.getpid()}.json"
    try:
        args = ["footprint", "--json", path]
        for pid in pids:
            args += ["-p", str(pid)]
        subprocess.run(args, capture_output=True, check=False, timeout=30)
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        for proc in data.get("processes", []):
            if proc.get("pid") in result and isinstance(proc.get("footprint"), int):
                result[proc["pid"]] = proc["footprint"]
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
    return result


def sample(prefix):
    table = processes()
    roots = find_app(table, prefix)
    pids = descendants(table, roots)
    fp = footprints(pids)
    procs = [{"pid": pid, "name": os.path.basename(table[pid]["command"].split(" -")[0].split(None, 1)[0]) if pid in table else "?", "cpuPercent": table[pid]["cpu"],
              "footprintMiB": (fp[pid] / 1048576 if fp[pid] is not None else None)} for pid in pids if pid in table]
    return {"t": time.time(), "processes": procs, "cpuPercentTotal": sum(p["cpuPercent"] for p in procs),
            "footprintMiBTotal": sum(p["footprintMiB"] for p in procs if p["footprintMiB"] is not None),
            "unreadableFootprints": sum(1 for p in procs if p["footprintMiB"] is None)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-path-prefix")
    parser.add_argument("--out")
    parser.add_argument("--stop-file")
    parser.add_argument("--interval", type=float, default=2.0)
    parser.add_argument("--wait-seconds", type=float, default=180.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        table = {1: {"pid": 1, "ppid": 0, "cpu": 0, "command": "/sbin/launchd"}, 10: {"pid": 10, "ppid": 1, "cpu": 5.0, "command": "/w/app/NativeMusic.app/Contents/MacOS/NativeMusic"},
                 11: {"pid": 11, "ppid": 10, "cpu": 2.5, "command": "/w/app/helper"}, 12: {"pid": 12, "ppid": 1, "cpu": 9.0, "command": "/other/NativeMusic"}}
        assert find_app(table, "/w/app/NativeMusic.app/") == [10] and descendants(table, [10]) == [10, 11]
        assert footprints([]) == {} and sample("/definitely/not/a/running/app/")["processes"] == []
        print("perf-sample self-test: ok")
        return 0
    if not (args.app_path_prefix and args.out and args.stop_file):
        parser.error("--app-path-prefix, --out and --stop-file are required")
    started, seen_app, last_seen = time.time(), False, time.time()
    with open(args.out, "a", encoding="utf-8") as out:
        while not os.path.exists(args.stop_file):
            row = sample(args.app_path_prefix)
            if row["processes"]:
                seen_app, last_seen = True, time.time()
                out.write(json.dumps(row) + "\n"); out.flush()
            elif not seen_app and time.time() - started > args.wait_seconds:
                print("perf-sample: the app never appeared", file=sys.stderr)
                return 3
            time.sleep(args.interval)
    return 0


if __name__ == "__main__":
    sys.exit(main())
