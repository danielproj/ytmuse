#!/usr/bin/env python3
"""T30.1 / SEC10: static rules for .github/workflows (no YAML library: the files are read as text, line by line).

  check-workflows.py --self-test    each rule against a planted violation and a clean control
  check-workflows.py                the repository's workflows

The rules:
  * a pull-request workflow (ci, license) names NO secret, no `environment`, never `pull_request_target` or `workflow_run`, and has read-only `contents`;
  * every workflow declares top-level `permissions`, and none grants `write-all`, `id-token: write` or anything but `contents: write` (release package job only);
  * secrets appear only in the release workflow, only in the job that has `environment: release`, and never in a `run:` command line (they pass through `env:`);
  * every `uses:` is a first-party `actions/*` action (tag-pinned actions are listed so they can be pinned to a commit before the first run);
  * `persist-credentials: false` on every checkout; no `curl | sh`, no `sudo` except xcode-select.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PR_WORKFLOWS = {"ci.yml", "license.yml"}


def jobs_of(lines):
    """[(job name, start, end)] for the entries directly under the top-level `jobs:`."""
    out, in_jobs = [], False
    starts = []
    for i, line in enumerate(lines):
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True; continue
        if in_jobs and re.match(r"^\S", line) and not line.startswith("#"):
            in_jobs = False
        if in_jobs:
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if m:
                starts.append((m.group(1), i))
    for n, (name, start) in enumerate(starts):
        end = starts[n + 1][1] if n + 1 < len(starts) else len(lines)
        out.append((name, start, end))
    return out


def check(name, text):
    problems, notes = [], []
    lines = text.splitlines()
    code = [l for l in lines if not l.lstrip().startswith("#")]
    body = "\n".join(code)
    if re.search(r"^\s*pull_request_target\s*:", body, re.M) or "pull_request_target" in re.sub(r"#.*", "", body):
        problems.append(f"{name}: uses pull_request_target")
    if re.search(r"workflow_run\s*:", body):
        problems.append(f"{name}: uses workflow_run")
    top_perm = re.search(r"^permissions:\s*\n((?:  .*\n)+)", text, re.M)
    if not top_perm:
        problems.append(f"{name}: no top-level permissions block")
    elif re.search(r"(write-all|id-token:\s*write)", body):
        problems.append(f"{name}: broad permission")
    elif re.search(r"contents:\s*write", top_perm.group(1)):
        problems.append(f"{name}: top-level contents: write")
    for l in code:
        if re.search(r"permissions:\s*write-all", l):
            problems.append(f"{name}: write-all")
    if name in PR_WORKFLOWS:
        if re.search(r"secrets\.", body):
            problems.append(f"{name}: a pull-request workflow names a secret")
        if re.search(r"^\s*environment:", body, re.M):
            problems.append(f"{name}: a pull-request workflow uses an environment")
        if re.search(r"contents:\s*write", body):
            problems.append(f"{name}: a pull-request workflow can write")
        if not re.search(r"^\s*(pull_request|push):", body, re.M):
            problems.append(f"{name}: no pull_request/push trigger")
    else:
        # secrets: only in a job with environment: release, only through env:
        for job, start, end in jobs_of(lines):
            segment = "\n".join(l for l in lines[start:end] if not l.lstrip().startswith("#"))
            if "secrets." in segment and not re.search(r"^\s*environment:\s*release\s*$", segment, re.M):
                problems.append(f"{name}: job {job} uses secrets outside the release environment")
        if re.search(r"^\s+(?:-\s+)?run:.*\$\{\{\s*secrets\.", body, re.M):
            problems.append(f"{name}: a secret is expanded inside a run command")
        in_run = False
        for l in code:
            if re.match(r"^\s+run:\s*[|>]", l): in_run = True; continue
            if in_run and re.match(r"^\s+-\s|^\s+[a-z-]+:\s", l) and not l.startswith("          "): in_run = False
            if in_run and "${{ secrets." in l:
                problems.append(f"{name}: a secret is expanded inside a multi-line run")
        if not re.search(r"tags:", body):
            problems.append(f"{name}: a non-PR workflow must be tag-triggered")
    for m in re.finditer(r"^\s*-?\s*uses:\s*(\S+)", body, re.M):
        action = m.group(1)
        if not action.startswith("actions/"):
            problems.append(f"{name}: third-party action {action}")
        elif not re.search(r"@[0-9a-f]{40}$", action):
            notes.append(f"{name}: {action} is tag-pinned (pin to a commit SHA before the first run)")
    for m in re.finditer(r"uses:\s*actions/checkout@\S+\s*\n((?:\s+.*\n)*?)(?=\s*-\s|\Z)", text):
        if "persist-credentials: false" not in m.group(1):
            problems.append(f"{name}: checkout keeps credentials")
    if re.search(r"(curl|wget)[^\n|]*\|\s*(ba)?sh", body):
        problems.append(f"{name}: pipes a download into a shell")
    if re.search(r"\bsudo\b(?!\s+xcode-select)", body):
        problems.append(f"{name}: sudo")
    if re.search(r"\$\{\{\s*github\.event\.(pull_request|issue|comment|head_commit)\.[a-z_.]*(title|body|message|ref|label)", body):
        problems.append(f"{name}: expands untrusted event text in a command")
    return problems, notes


def self_test():
    good = """name: ci
on:
  pull_request:
permissions:
  contents: read
jobs:
  a:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - run: ./scripts/ci.sh
"""
    cases = {
        "pull_request_target": good.replace("pull_request:", "pull_request_target:"),
        "no permissions": good.replace("permissions:\n  contents: read\n", ""),
        "write-all": good.replace("contents: read", "write-all"),
        "secret in PR workflow": good.replace("./scripts/ci.sh", "echo ${{ secrets.X }}"),
        "environment in PR workflow": good.replace("    runs-on: macos-latest", "    runs-on: macos-latest\n    environment: release"),
        "third-party action": good.replace("actions/checkout@v4", "someone/else@v1"),
        "checkout keeps credentials": good.replace("          persist-credentials: false\n", ""),
        "curl pipe": good.replace("./scripts/ci.sh", "curl https://x.example/i.sh | sh"),
        "sudo": good.replace("./scripts/ci.sh", "sudo rm -rf /x"),
        "id-token": good.replace("contents: read", "contents: read\n  id-token: write"),
        "untrusted title": good.replace("./scripts/ci.sh", "echo ${{ github.event.pull_request.title }}"),
    }
    failures = []
    p, _ = check("ci.yml", good)
    if p:
        failures.append(f"clean control flagged: {p}")
    for label, text in cases.items():
        p, _ = check("ci.yml", text)
        if not p:
            failures.append(f"missed: {label}")
    release = """name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: read
jobs:
  verify:
    runs-on: macos-latest
    steps:
      - run: ./scripts/ci.sh
  package:
    runs-on: macos-latest
    environment: release
    permissions:
      contents: write
    env:
      K: ${{ secrets.K }}
    steps:
      - run: ./scripts/package-release.sh
"""
    if check("release.yml", release)[0]:
        failures.append(f"clean release control flagged: {check('release.yml', release)[0]}")
    if not check("release.yml", release.replace("      - run: ./scripts/ci.sh", "      - run: echo\n    env:\n      K: ${{ secrets.K }}"))[0]:
        failures.append("missed: a secret in a job without the release environment")
    if not check("release.yml", release.replace("./scripts/package-release.sh", "echo ${{ secrets.K }}"))[0]:
        failures.append("missed: a secret expanded in a run")
    if failures:
        print("SELF-TEST FAILED:\n  " + "\n  ".join(failures)); return 1
    print(f"check-workflows self-test: ok ({len(cases) + 2} violations caught, clean controls passed)")
    return 0


def main():
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    files = sorted((ROOT / ".github/workflows").glob("*.yml"))
    if {f.name for f in files} != {"ci.yml", "license.yml", "release.yml"}:
        print(f"expected ci.yml, license.yml and release.yml, found {[f.name for f in files]}"); sys.exit(1)
    problems, notes = [], []
    for f in files:
        p, n = check(f.name, f.read_text())
        problems += p; notes += n
    for n in sorted(set(notes)):
        print("note:", n)
    if problems:
        print("check-workflows FAILED:\n  " + "\n  ".join(problems)); sys.exit(1)
    print(f"check-workflows: {len(files)} workflows ok (no secret in a PR workflow, secrets only in the release environment, first-party actions only)")


if __name__ == "__main__":
    main()
