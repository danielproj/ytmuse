#!/usr/bin/env python3
"""Compares the tests a suite DISCOVERED with the tests it EXECUTED (C1 item 12).

`swift test` has been seen to exit 0 after running only part of a suite (a critic saw T06 run 35
of 161 discovered PlaybackTests). Every suite in scripts/test.sh therefore runs through this check:

  count-tests.py check   --list <swift test list output> --filter <regex or ''> --log <run output>
  count-tests.py ui      (--expect <test name> ... | --expect-file <swift file>) --log <xcodebuild output>
  count-tests.py --self-test

`check` reads the discovery list (one id per line: XCTest `Module.Class/test`, Swift Testing
`Module.Suite/test()`), keeps the ids the SwiftPM `--filter` regexes select, and compares them with
what the run output reports:

  * XCTest: every discovered id must appear as `Test Case '-[Module.Class test]' passed|failed|skipped`
    (compared per id, so the missing tests are named).
  * Swift Testing: the sum of `Test run with N tests` over the run (N includes skipped tests) must be at
    least the number of discovered Swift Testing tests; skipped ones (`➜ Test ... skipped.`) are counted
    and printed, never silently treated as run.

Exit 0 only when nothing is missing. A filter that selects nothing, or a run that printed no results
at all, is a failure too. Skips are reported (`ran`, `skipped`); `--max-skips N` makes more than N a failure.
"""
import argparse, re, sys

XC_RESULT = re.compile(r"Test Case '-\[(?P<cls>[\w.]+) (?P<name>[^\]\s]+)\]' (?P<state>passed|failed|skipped)")
ST_RUN = re.compile(r"Test run with (?P<n>\d+) tests?\b")
ST_SKIP = re.compile(r"^➜ Test .* skipped\.\s*$")


def parse_list(text):
    xctest, swift_testing = set(), set()
    for line in text.splitlines():
        line = line.strip()
        if not line or "/" not in line or line.startswith(("Building", "Compiling", "Build ", "[")):
            continue
        (swift_testing if line.endswith(")") else xctest).add(line)
    return xctest, swift_testing


def select(ids, filters):
    """SwiftPM semantics: a test runs when ANY --filter regex matches its id (re.search)."""
    if not filters:
        return set(ids)
    return {i for i in ids if any(re.search(f, i) for f in filters)}


def parse_log(text):
    xc = {}
    for m in XC_RESULT.finditer(text):
        xc[f"{m['cls']}/{m['name']}"] = m["state"]
    st_total = sum(int(m["n"]) for m in ST_RUN.finditer(text))
    st_runs = len(ST_RUN.findall(text))
    st_skipped = sum(1 for line in text.splitlines() if ST_SKIP.match(line))
    return xc, st_total, st_runs, st_skipped


def check(list_text, filters, log_text, max_skips=None):
    xc_all, st_all = parse_list(list_text)
    xc_want, st_want = select(xc_all, filters), select(st_all, filters)
    problems = []
    if not xc_want and not st_want:
        problems.append("the filter selected no discovered test")
    xc_done, st_total, st_runs, st_skipped = parse_log(log_text)
    missing = sorted(i for i in xc_want if i not in xc_done)
    xc_skipped = sorted(i for i, s in xc_done.items() if s == "skipped" and i in xc_want)
    if missing:
        problems.append(f"{len(missing)} of {len(xc_want)} XCTest cases never ran: " + ", ".join(missing[:8]) + (" …" if len(missing) > 8 else ""))
    if st_want and st_runs == 0:
        problems.append(f"{len(st_want)} Swift Testing tests were discovered but the run printed no 'Test run with N tests' line")
    elif st_total < len(st_want):
        problems.append(f"Swift Testing ran {st_total} of {len(st_want)} discovered tests")
    skipped = len(xc_skipped) + st_skipped
    if max_skips is not None and skipped > max_skips:
        problems.append(f"{skipped} tests were skipped (at most {max_skips} expected)")
    summary = (f"discovered XCTest={len(xc_want)} SwiftTesting={len(st_want)}; "
               f"executed XCTest={len(xc_want) - len(missing)} SwiftTesting={min(st_total, len(st_want)) if st_want else 0} (reported {st_total}); "
               f"skipped={skipped} (XCTest {len(xc_skipped)}, Swift Testing {st_skipped})")
    return problems, summary


def check_ui(expected, log_text):
    done = {}
    for m in XC_RESULT.finditer(log_text):
        done[m["name"]] = m["state"]
    missing = [name for name in expected if name not in done]
    skipped = sorted(n for n in expected if done.get(n) == "skipped")
    problems = [f"{len(missing)} of {len(expected)} UI cases never ran: " + ", ".join(missing)] if missing else []
    return problems, f"UI discovered={len(expected)} executed={len(expected) - len(missing)} skipped={len(skipped)} {skipped}"


SELF_LIST = "\n".join(
    [f"Mod.Cls/test{i}" for i in range(161)] + [f"Mod.Suite/case{i}()" for i in range(10)] + ["Other.Thing/testOther", "Other.Suite/x()"])


def _xc_log(n, states=None):
    return "\n".join(f"Test Case '-[Mod.Cls test{i}]' started.\nTest Case '-[Mod.Cls test{i}]' {(states or {}).get(i, 'passed')} (0.1 seconds)." for i in range(n))


def scan_runner(lines):
    """Lines of scripts/test.sh that run tests without the counting helpers: any `swift test` that is not a
    `list` call or inside the helper, and any line that runs `xcodebuild` or the `test-native-latin.py`
    wrapper (with or without `-only-testing`, direct or through an `args` array) outside `counted_ui_test`."""
    inside, bare = False, []
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        # The two counting helpers themselves may name the tools they wrap (counted_ui_test prebuilds with build-for-testing).
        if stripped.startswith(("counted_swift_test()", "counted_ui_test()")): inside = True
        elif inside and stripped == "}": inside = False
        if inside or stripped.startswith("#"): continue
        if re.search(r"(^|[;&(]|\$\()\s*swift test\b", stripped) and not stripped.endswith(" list)") and not stripped.endswith(" list"):
            bare.append(f"test.sh:{number}: {stripped}")
        runs_ui = re.search(r"\bxcodebuild\b|test-native-latin\.py", stripped) and not stripped.startswith(("args=(", "echo "))
        if runs_ui and not stripped.startswith("counted_ui_test "):
            bare.append(f"test.sh:{number}: {stripped[:90]}")
    return bare


def self_test():
    cases = []

    def expect(name, problems, want_fail, needle=None):
        ok = bool(problems) == want_fail and (needle is None or any(needle in p for p in problems))
        cases.append((name, ok, problems))

    full = _xc_log(161) + "\n✔ Test run with 10 tests in 1 suites passed after 1 seconds.\n"
    p, s = check(SELF_LIST, ["Mod\\."], full)
    expect("a complete run passes", p, False)
    partial = _xc_log(35) + "\n✔ Test run with 10 tests in 1 suites passed after 1 seconds.\n"
    p, s = check(SELF_LIST, ["Mod\\."], partial)
    expect("35 of 161 XCTest cases fails and names the rest", p, True, "126 of 161 XCTest cases never ran")
    p, s = check(SELF_LIST, ["Mod\\."], _xc_log(161) + "\n✔ Test run with 4 tests in 1 suites passed after 1 seconds.\n")
    expect("a partial Swift Testing run fails", p, True, "Swift Testing ran 4 of 10")
    p, s = check(SELF_LIST, ["Mod\\."], _xc_log(161))
    expect("discovered Swift Testing tests with no result line fail", p, True, "printed no 'Test run with")
    p, s = check(SELF_LIST, ["Mod\\."], "")
    expect("an empty log (a crashed run) fails", p, True)
    p, s = check(SELF_LIST, ["NoSuchSuite"], full)
    expect("a filter that selects nothing fails", p, True, "selected no discovered test")
    p, s = check(SELF_LIST, ["Mod.Cls"], _xc_log(161))
    expect("a filter with no Swift Testing tests needs none", p, False)
    skipping = _xc_log(161, {3: "skipped", 4: "skipped"}) + "\n➜ Test case2() skipped.\n✔ Test run with 10 tests in 1 suites passed after 1 seconds.\n"
    p, s = check(SELF_LIST, ["Mod\\."], skipping)
    expect("skips are counted and reported, not hidden", p, False)
    cases.append(("the skip count is exact", "skipped=3 (XCTest 2, Swift Testing 1)" in s, [s]))
    p, s = check(SELF_LIST, ["Mod\\."], skipping, max_skips=2)
    expect("more skips than expected fails", p, True, "3 tests were skipped")
    many = _xc_log(161) + "\n✔ Test run with 6 tests in 1 suites passed after 1 seconds.\n✔ Test run with 4 tests in 1 suites passed after 1 seconds.\n"
    p, s = check(SELF_LIST, ["Mod\\."], many)
    expect("runs of several test bundles are summed", p, False)
    p, s = check(SELF_LIST, [], full.replace("Test Case '-[Mod.Cls test0]'", "Test Case '-[Mod.Cls testZ]'"))
    expect("an unfiltered run is held to the whole list (one case renamed → missing)", p, True)
    ui = "Test Case '-[UITests.UITests testA]' passed (1 seconds).\nTest Case '-[UITests.UITests testB]' skipped (0 seconds).\n"
    p, s = check_ui(["testA", "testB"], ui)
    expect("UI cases that passed or were skipped are accounted for", p, False)
    p, s = check_ui(["testA", "testB", "testC"], ui)
    expect("a UI case that never ran fails", p, True, "testC")
    # The runner itself: every `swift test` and every UI `xcodebuild` in scripts/test.sh goes through the helpers.
    import os
    runner = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "test.sh")).read().splitlines()
    bare = scan_runner(runner)
    cases.append(("every swift test in scripts/test.sh goes through counted_swift_test", not bare, bare))
    joined = "\n".join(runner)
    cases.append(("the counting helpers are defined and used", "counted_swift_test()" in joined and joined.count("counted_swift_test ") >= 10 and "counted_ui_test " in joined, []))
    # W17 rework (F6): the production-store guard is part of EVERY suite's preamble, before the first suite branch.
    guard_call = "counted_swift_test 'ProductionStoreGuardTests|ProductionStoreGuardRuleTests'"
    first_suite = min((joined.index(m) for m in ('if [[ "$2" == T08 ]]', 'if [[ "$2" == T17 ]]', 'if [[ "$2" == T16 ]]') if m in joined), default=-1)
    cases.append(("the production-store guard runs in the preamble of every suite", guard_call in joined and 0 <= joined.index(guard_call) < first_suite, []))
    fixture_ok = ["counted_swift_test() {", "  swift test --package-path P \"$@\" list > \"$list\"", "  swift test --package-path P \"$@\" --filter \"$f\"", "}",
                  "  discovery=$(swift test --package-path P list)", "  counted_swift_test Foo", "  counted_ui_test a -- xcodebuild -x",
                  "# swift test mention in a comment"]
    cases.append(("the runner scan accepts the helper, list calls and comments", scan_runner(fixture_ok) == [], scan_runner(fixture_ok)))
    cases.append(("the runner scan flags a bare swift test", len(scan_runner(fixture_ok + ["  swift test --package-path P --filter Foo"])) == 1, []))
    cases.append(("the runner scan flags a bare swift test inside a command substitution", len(scan_runner(fixture_ok + ["x=$(swift test --package-path P)"])) == 1, []))
    helper_body = ["counted_ui_test() {", "  [[ ${a} == xcodebuild ]] && x=1", "}"]
    cases.append(("the UI helper may name the tool it wraps, but the same line outside it is flagged", scan_runner(fixture_ok + helper_body) == [] and len(scan_runner(fixture_ok + ["  [[ ${a} == xcodebuild ]] && x=1"])) == 1, []))
    cases.append(("the runner scan flags a UI xcodebuild outside the helper", len(scan_runner(fixture_ok + ["  xcodebuild -only-testing:A/B test"])) == 1, []))
    # The two shapes scripts/test.sh really uses for a UI run, unwrapped (REWORK 1: both went undetected before).
    cases.append(("the runner scan flags a bare xcodebuild over the args array", len(scan_runner(fixture_ok + ['  xcodebuild "${args[@]}"'])) == 1, []))
    cases.append(("the runner scan flags the test-native-latin wrapper outside the helper", len(scan_runner(fixture_ok + ['python3 scripts/test-native-latin.py xcodebuild "${args[@]}"'])) == 1, []))
    cases.append(("the runner scan flags the wrapper even when xcodebuild is not on the line", len(scan_runner(fixture_ok + ['python3 scripts/test-native-latin.py "${wrapped[@]}"'])) == 1, []))
    cases.append(("the runner scan accepts args definitions and the wrapped forms", scan_runner(fixture_ok + ["  args=(-project A -scheme B -only-testing:A/B test)", '  counted_ui_test --all-in F -- python3 scripts/test-native-latin.py xcodebuild "${args[@]}"', '  counted_ui_test t -- xcodebuild "${args[@]}"']) == [], []))
    p, s = check_ui(["testA"], "")
    expect("a UI run that printed no results fails", p, True, "testA")
    bad = [name for name, ok, details in cases if not ok]
    for name, ok, details in cases:
        print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  {details}"))
    return 1 if bad else 0


def main():
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("check")
    c.add_argument("--list", required=True); c.add_argument("--filter", default=""); c.add_argument("--log", required=True)
    c.add_argument("--max-skips", type=int)
    u = sub.add_parser("ui")
    u.add_argument("--expect", nargs="+"); u.add_argument("--expect-file"); u.add_argument("--log", required=True)
    args = parser.parse_args()
    log = open(args.log, errors="replace").read()
    if args.mode == "check":
        filters = [args.filter] if args.filter else []
        problems, summary = check(open(args.list, errors="replace").read(), filters, log, args.max_skips)
    else:
        expected = args.expect or re.findall(r"func (test\w+)\(", open(args.expect_file).read()) if (args.expect or args.expect_file) else []
        if not expected:
            print("test count FAILED: no UI test names to expect", file=sys.stderr); sys.exit(1)
        problems, summary = check_ui(expected, log)
    print("test count: " + summary)
    for problem in problems:
        print("test count FAILED: " + problem, file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
