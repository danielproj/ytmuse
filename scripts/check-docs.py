#!/usr/bin/env python3
"""T30.5: the documentation tells the truth and its examples run.

  check-docs.py --self-test      the rules against planted violations and clean controls
  check-docs.py --static-only    everything except executing the ```sh run examples
  check-docs.py                  everything, including running the examples

Rules:
  * required documents exist; every relative link resolves to a file (and a heading, for #anchors);
  * a fenced `sh run` block is EXECUTED (bash -euo pipefail, repository root, no YTMUSE_/GOOGLE_/signing variables, a timeout) and must exit 0;
  * every other `sh`/`bash` block is syntax-checked (bash -n) and every script or package path it names must exist;
  * the README says there is no release and names the open gates, and no document markets unfinished work: no "production-ready", "feature complete",
    "available now", "official" (except "not official / unofficial / not endorsed"); a capability-matrix row uses only the documented status words, and
    never "complete" or "done".
"""
import os, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ["README.md", "CONTRIBUTING.md", "SECURITY.md", "PRIVACY.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "Docs/Distribution.md", "Docs/Capability-Matrix.md",
            "Docs/Publishing-Checklist.md", "Docs/Build.md", "Docs/sbom.cdx.json"]
CHECKED = ["README.md", "CONTRIBUTING.md", "SECURITY.md", "PRIVACY.md", "Docs/Distribution.md", "Docs/Capability-Matrix.md", "Docs/Publishing-Checklist.md", "Docs/Build.md", "Docs/Screenshots/README.md"]
STATUSES = ["Built, fixtures only", "Built, live unverified", "In progress", "Not started", "Not available"]
MARKETING = re.compile(r"(?i)\b(production[- ]ready|feature[- ]complete|fully[- ](?:functional|featured|implemented)|stable release|now available|available now|download (?:it )?now|battle[- ]tested)\b")
OFFICIAL = re.compile(r"(?i)(?<!not an )(?<!not )(?<!un)\bofficial\b")
SECRET_ENV = re.compile(r"^(YTMUSE_|GOOGLE|GH_|GITHUB_|APPLE_|NOTARY|AWS_|ANTHROPIC)")


def slug(heading):
    s = re.sub(r"[`*_]", "", heading.strip().lower())
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def blocks(text):
    """[(info string, body, start line)] of every fenced code block."""
    out, lines, i = [], text.splitlines(), 0
    while i < len(lines):
        m = re.match(r"^```(\S*)\s*(.*)$", lines[i])
        if m:
            start, body = i + 1, []
            i += 1
            while i < len(lines) and not lines[i].startswith("```"):
                body.append(lines[i]); i += 1
            out.append(((m.group(1) + " " + m.group(2)).strip(), "\n".join(body), start))
        i += 1
    return out


def clean_env():
    env = {k: v for k, v in os.environ.items() if not SECRET_ENV.match(k)}
    env["HOME"] = os.environ.get("HOME", "/tmp")
    return env


def run_example(root, body, timeout=900):
    return subprocess.run(["bash", "-euo", "pipefail", "-c", body], cwd=root, env=clean_env(), capture_output=True, text=True, timeout=timeout)


def check(root: Path, files, required, run_examples):
    problems, executed, syntax = [], 0, 0
    for r in required:
        if not (root / r).exists():
            problems.append(f"missing document: {r}")
    for rel in files:
        path = root / rel
        if not path.exists():
            continue
        text = path.read_text()
        prose = re.sub(r"```.*?```", "", text, flags=re.S)
        for m in re.finditer(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)|!\[[^\]]*\]\(([^)\s]+)\)", text):
            target = m.group(1) or m.group(2)
            if re.match(r"^(https?:|mailto:)", target):
                continue
            file_part, _, anchor = target.partition("#")
            dest = (path.parent / file_part).resolve() if file_part else path
            if not dest.exists():
                problems.append(f"{rel}: link to a missing file: {target}"); continue
            if anchor and dest.suffix == ".md":
                heads = {slug(h) for h in re.findall(r"^#+\s+(.*)$", dest.read_text(), re.M)}
                if anchor not in heads:
                    problems.append(f"{rel}: link to a missing heading: {target}")
        for m in MARKETING.finditer(prose):
            problems.append(f"{rel}: marketing claim {m.group(0)!r}")
        for m in OFFICIAL.finditer(prose):
            problems.append(f"{rel}: 'official' without a negation near {prose[max(0, m.start() - 30):m.end() + 10]!r}")
        for info, body, line in blocks(text):
            words = info.split()
            if not words or words[0] not in ("sh", "bash", "zsh"):
                continue
            where = f"{rel}:{line}"
            if "run" in words[1:]:
                if run_examples:
                    done = run_example(root, body)
                    executed += 1
                    if done.returncode != 0:
                        problems.append(f"{where}: the example exited {done.returncode}: {(done.stderr or done.stdout).strip()[-300:]}")
                else:
                    syntax += 1
                    if subprocess.run(["bash", "-n", "-c", body], capture_output=True).returncode != 0:
                        problems.append(f"{where}: example has a syntax error")
                continue
            syntax += 1
            check_syntax = subprocess.run(["bash", "-n"], input=body, capture_output=True, text=True)
            if check_syntax.returncode != 0:
                problems.append(f"{where}: shell syntax: {check_syntax.stderr.strip()[:200]}")
            for token in re.findall(r"(?:^|\s)(\.?/?(?:scripts|Packages|Docs|Tools|Tests|App|Extensions)/[A-Za-z0-9_./\-]+)", body):
                token = token.strip().lstrip("./")
                if "*" in token or token.endswith("/"):
                    token = token.rstrip("/")
                if token and not (root / token).exists():
                    problems.append(f"{where}: names a path that does not exist: {token}")
    readme = (root / "README.md").read_text() if (root / "README.md").exists() else ""
    if readme:
        if not re.search(r"(?i)no release", readme):
            problems.append("README.md: must say there is no release")
        if not re.search(r"G01", readme) or not re.search(r"(?i)\*\*open\*\*", readme):
            problems.append("README.md: must name the open gates (G01 and **open**)")
        if "Docs/Capability-Matrix.md" not in readme:
            problems.append("README.md: must link the capability matrix")
        if not re.search(r"(?i)not endorsed|independent", readme):
            problems.append("README.md: must explain independent project status")
        for image in re.findall(r"!\[[^\]]*\]\(([^)\s]+)\)", readme):
            if not (root / image).exists():
                problems.append(f"README.md: missing screenshot {image}")
    matrix = root / "Docs/Capability-Matrix.md"
    if matrix.exists():
        rows = [l for l in matrix.read_text().splitlines() if l.startswith("|") and not re.match(r"^\|\s*(-|Area)", l)]
        if not rows:
            problems.append("Capability-Matrix.md: no rows")
        for row in rows:
            cells = [c.strip() for c in row.strip("|").split("|")]
            status = cells[1] if len(cells) > 1 else ""
            if not any(status.startswith(s) for s in STATUSES):
                problems.append(f"Capability-Matrix.md: status {status!r} is not one of {STATUSES}")
            if re.search(r"(?i)\b(complete|done|finished|fully supported)\b", status):
                problems.append(f"Capability-Matrix.md: a row claims completion: {status!r}")
    return problems, executed, syntax


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Docs").mkdir(); (root / "scripts").mkdir()
        (root / "scripts/real.sh").write_text("#!/bin/bash\n")
        good_readme = "# X\n\nThere is no release. Gates: G01 **open**.\n\nIndependent, not endorsed. See [matrix](Docs/Capability-Matrix.md).\n\n```sh run\ntrue\n```\n\n```sh\n./scripts/real.sh\n```\n"
        matrix = "| Area | Status | Notes |\n| --- | --- | --- |\n| A | Built, fixtures only | x |\n"
        def build(readme=good_readme, extra="", mx=matrix):
            (root / "README.md").write_text(readme + extra); (root / "Docs/Capability-Matrix.md").write_text(mx)
            return check(root, ["README.md"], ["README.md"], run_examples=True)[0]
        if build():
            failures.append(f"clean control flagged: {build()}")
        cases = {
            "dead link": ("", "\n[x](Docs/missing.md)\n", matrix),
            "dead heading": ("", "\n[x](Docs/Capability-Matrix.md#nope)\n", matrix),
            "failing run example": ("", "\n```sh run\nfalse\n```\n", matrix),
            "shell syntax": ("", "\n```sh\nif then\n```\n", matrix),
            "missing script": ("", "\n```sh\n./scripts/ghost.sh\n```\n", matrix),
            "marketing": ("", "\nThe app is production-ready.\n", matrix),
            "official": ("", "\nThe official client.\n", matrix),
            "bad status": ("", "", matrix.replace("Built, fixtures only", "Complete")),
            "done status": ("", "", matrix.replace("Built, fixtures only", "Built, fixtures only, done")),
        }
        for label, (_r, extra, mx) in cases.items():
            if not build(extra=extra, mx=mx):
                failures.append(f"missed: {label}")
        if not build(readme="# X\n\nHello.\n"):
            failures.append("missed: README without the no-release statement")
        if build(extra="\nThis is not an official app and an unofficial client.\n"):
            failures.append("negated 'official' flagged")
        # the example gets no secrets
        os.environ["YTMUSE_FEED_KEY"] = "should-not-be-visible"
        (root / "README.md").write_text(good_readme.replace("true\n```", 'test -z "${YTMUSE_FEED_KEY:-}"\n```', 1))
        if check(root, ["README.md"], ["README.md"], True)[0]:
            failures.append("an example could see a secret-looking variable")
        del os.environ["YTMUSE_FEED_KEY"]
    if failures:
        print("SELF-TEST FAILED:\n  " + "\n  ".join(failures)); return 1
    print(f"check-docs self-test: ok ({len(cases) + 1} violations caught, clean control passed, examples run without secrets)")
    return 0


def main():
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    problems, executed, syntax = check(ROOT, CHECKED, REQUIRED, run_examples="--static-only" not in sys.argv)
    if problems:
        print("check-docs FAILED:\n  " + "\n  ".join(problems)); sys.exit(1)
    print(f"check-docs: {len(CHECKED)} documents; {executed} example(s) executed, {syntax} block(s) syntax-checked; links, status words and honesty rules ok")


if __name__ == "__main__":
    main()
