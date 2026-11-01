#!/usr/bin/env python3
"""T30.5 / SEC10: scan the repository for sessions, cookies, tokens, keys, e-mail addresses, Team IDs and the account holder's personal data.

  scan-repository.py --self-test                     the rules against planted samples (and clean controls)
  scan-repository.py --tree                          every tracked file in the working tree
  scan-repository.py --history                       every blob reachable from any ref (the whole public history)
  scan-repository.py --images                        tracked images: PNG metadata chunks, plus OCR text through macOS Vision
  scan-repository.py --json FILE                     write the report (matches are redacted: a rule, a path, a short fingerprint, never the value)
  scan-repository.py --fail-on high                  exit 1 when a finding of that severity or worse remains after the allowlist

Personal terms (the macOS account name, the account holder's full name, the computer names and the git identity) are read from THIS machine at run
time and never written to the repository or to the report. `--personal-term TERM` adds more.

This script only READS: it never rewrites history, never deletes a file and never contacts a service. Findings in history are reported for the
operator; findings in the working tree are fixed in the working tree (see Docs/Publishing-Checklist.md).
"""
import argparse, collections, hashlib, json, os, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEVERITY = {"low": 0, "medium": 1, "high": 2}

# (id, severity, bytes regex, description). The regex's group 0 is the evidence; it is never printed, only fingerprinted.
RULES = [
    ("google-session-cookie", "high", rb"""\b(?:SAPISID|APISID|HSID|SSID|SID|__Secure-[13]PSID|__Secure-[13]PAPISID|__Secure-[13]PSIDTS|__Secure-[13]PSIDCC|LOGIN_INFO)\s*[=:]\s*["']?[A-Za-z0-9_\-./%]{24,}""", "a Google session cookie with a value"),
    ("authorization-header", "high", rb"""Authorization:\s*(?:Bearer|SAPISIDHASH|Basic)\s+[A-Za-z0-9._\-=/+]{20,}""", "an Authorization header with a credential"),
    ("sapisidhash", "high", rb"""SAPISIDHASH\s+\d{9,}_[0-9a-f]{40}""", "a SAPISIDHASH value"),
    ("google-access-token", "high", rb"""\bya29\.[0-9A-Za-z_\-]{30,}""", "a Google OAuth access token"),
    ("google-refresh-token", "high", rb"""\b1//0[0-9A-Za-z_\-]{30,}""", "a Google OAuth refresh token"),
    ("google-client-secret", "high", rb"""\bGOCSPX-[0-9A-Za-z_\-]{20,}""", "a Google OAuth client secret"),
    ("google-api-key", "medium", rb"""\bAIza[0-9A-Za-z_\-]{35}\b""", "a Google API key"),
    ("jwt", "high", rb"""\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}""", "a JSON Web Token"),
    ("private-key", "high", rb"""-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----""", "a private key block"),
    ("github-token", "high", rb"""\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b""", "a GitHub token"),
    ("cloud-key", "high", rb"""\b(?:AKIA[0-9A-Z]{16}|xox[abprs]-[0-9A-Za-z\-]{10,})\b""", "an AWS access key or a Slack token"),
    ("secret-assignment", "medium", rb"""(?i)\b(?:client_secret|api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd)\s*[:=]\s*["'][^"'\s$<{(]{20,}["']""", "a secret-looking assignment"),
    ("team-id-setting", "high", rb"""\bDEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}\b""", "a Team ID in a build setting"),
    ("team-id-codesign", "high", rb"""\b(?:TeamIdentifier=[A-Z0-9]{10}\b|Authority=(?:Apple Development|Developer ID Application|Developer ID Installer|Apple Distribution|3rd Party Mac Developer Application): [^\n]*\([A-Z0-9]{10}\))""", "a Team ID in codesign output"),
    ("team-id-identity", "high", rb"""\b(?:Apple Development|Developer ID Application|Developer ID Installer|Apple Distribution): [^\n"'<>\\]{3,60}\([A-Z0-9]{10}\)""", "a signing identity naming a Team ID"),
    ("team-id-app-group", "high", rb"""(?<![A-Za-z0-9$(])[A-Z0-9]{10}\.(?:group\.)?local\.native-music""", "an App Group prefixed with a Team ID"),
    ("team-id-requirement", "high", rb"""certificate leaf\[subject\.OU\]\s*=\s*"?[A-Z0-9]{10}\b""", "a Team ID in a designated requirement"),
    ("email", "medium", rb"""(?<![A-Za-z0-9._%+\-])[A-Za-z0-9][A-Za-z0-9._%+\-]{0,63}@[A-Za-z0-9][A-Za-z0-9.\-]{0,253}\.[A-Za-z]{2,24}\b""", "an e-mail address"),
    ("home-path", "medium", rb"""/Users/([A-Za-z0-9][A-Za-z0-9._\-]{1,40})/""", "an absolute path under a macOS home folder (names the account)"),
    ("anonymous-visitor-id", "low", rb"""\b(?:visitorData|VISITOR_INFO1_LIVE|VISITOR_PRIVACY_METADATA)["']?\s*[:=]\s*["']?[A-Za-z0-9_\-%]{16,}""", "a YouTube visitor identifier (anonymous, but per-browser)"),
]
RULE_BY_ID = {r[0]: r for r in RULES}
COMPILED = [(rid, sev, re.compile(rx), desc) for rid, sev, rx, desc in RULES]

PLACEHOLDER_TEAMS = {b"XXXXXXXXXX", b"ABCDE12345", b"0000000000", b"TEAMID1234", b"AAAAAAAAAA", b"1234567890", b"ABCDEFGHIJ"}
SYNTHETIC_TEAM_PREFIX = b"SYNTH"   # the signing tests' stand-in identities (Tests/Build/test-build-signing.sh): never a real Team ID
BENIGN_EMAIL_DOMAINS = (b"example", b"music.youtube.com", b"accounts.google.com", b"i.ytimg.com", b"creativecommons.org", b"example.com", b"example.org", b"example.net", b"example.invalid", b"invalid", b"test", b"localhost", b"users.noreply.github.com", b"noreply.github.com",
                        b"anthropic.com", b"nativemusic.invalid", b"ytmuse.invalid")
FILE_LIKE_TLDS = {b"png", b"jpg", b"jpeg", b"gif", b"svg", b"pdf", b"json", b"plist", b"swift", b"md", b"txt", b"html", b"js", b"css", b"xcassets", b"strings", b"icns", b"tiff",
                  b"heic", b"mov", b"mp4", b"m4a", b"mp3", b"wav", b"caf", b"sh", b"py", b"yml", b"yaml", b"xml", b"sdef", b"xcstrings", b"app", b"dmg", b"log", b"entitlements"}
BENIGN_HOME_USERS = {b"pat", b"patcanary", b"Shared", b"runner", b"user", b"you", b"example", b"name", b"username", b"USER", b"me", b"someone", b"person", b"yourname", b"appleseed", b"Guest", b"test", b"tester", b"x", b"admin"}
# Path-scoped allowances: a third-party sample project's own Team ID (kept as an input to a design study; not this project's, and excluded from the public snapshot).
PATH_ALLOW = {("team-id-setting", "artifacts/harness/nodes/V01/raw/apple-sample-project.pbxproj")}
# The standard RFC 6749 / OpenID example credential "s6BhdRkqt3:gX1fBat3bV", quoted by the copied specification text.
KNOWN_EXAMPLE = {b"czZCaGRSa3F0MzpnWDFmQmF0M2JW"}
# Published values that are not secrets: Google's own public web client key is shipped in every YouTube Music page.
KNOWN_PUBLIC = {b"AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30"}


def personal_terms(extra):
    """Terms naming this machine's account holder, read at run time. Never stored."""
    terms = {}
    def add(kind, value):
        value = (value or "").strip()
        if len(value) >= 4 and value.lower() not in {"admin", "user", "root", "mac", "macbook", "localhost"}:
            terms[value] = kind
    add("macos-account-name", Path.home().name)
    for kind, cmd in (("full-name", ["id", "-F"]), ("computer-name", ["scutil", "--get", "ComputerName"]), ("local-host-name", ["scutil", "--get", "LocalHostName"]),
                      ("git-name", ["git", "config", "--get", "user.name"]), ("git-email", ["git", "config", "--get", "user.email"])):
        try:
            add(kind, subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout)
        except Exception:
            pass
    for t in extra:
        add("extra", t)
    return terms


def compile_personal(terms):
    out = []
    for term, kind in terms.items():
        out.append((kind, term, re.compile(re.escape(term.encode()), re.I)))
        if kind == "full-name" and " " in term:      # "First Last" also matches as "FirstLast" and "first.last"
            out.append((kind, term, re.compile(re.escape(term.replace(" ", "").encode()), re.I)))
    return out


def fingerprint(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()[:10]


def accept(rid: str, match: "re.Match", data: bytes) -> bool:
    """The allowlist: a hit that is a published value, a placeholder or a file name is not a finding."""
    value = match.group(0)
    if rid in ("team-id-setting", "team-id-codesign", "team-id-identity", "team-id-app-group", "team-id-requirement"):
        team = re.findall(rb"[A-Z0-9]{10}", value)
        return bool(team) and all(t in PLACEHOLDER_TEAMS or t.startswith(SYNTHETIC_TEAM_PREFIX) for t in team[-1:])
    if rid == "email":
        domain = value.rsplit(b"@", 1)[1].lower()
        tld = domain.rsplit(b".", 1)[1]
        if tld in FILE_LIKE_TLDS or re.fullmatch(rb"\d+x(?:\.[a-z]+)?", domain.split(b".", 1)[0]) or domain.split(b".", 1)[0] in (b"2x", b"3x", b"1x"):
            return True
        return any(domain == d or domain.endswith(b"." + d) for d in BENIGN_EMAIL_DOMAINS)
    if rid == "home-path":
        return match.group(1) in BENIGN_HOME_USERS or match.group(1).startswith(b"<")
    if rid == "google-api-key":
        return value in KNOWN_PUBLIC
    if rid == "authorization-header" and any(k in value for k in KNOWN_EXAMPLE):
        return True
    if rid == "sapisidhash":
        return value.startswith(b"SAPISIDHASH 1700000000_")       # the connection tests' fixed vector, computed from a made-up cookie value
    if rid in ("jwt", "secret-assignment", "google-session-cookie", "authorization-header", "anonymous-visitor-id", "google-access-token", "google-refresh-token"):
        window = data[max(0, match.start() - 80): match.end() + 40].lower()
        return any(marker in window for marker in (b"canary", b"redacted", b"placeholder", b"fixture-value", b"synthetic", b"not-a-real", b"example-only", b"<redacted", b"xxxxxxxx"))
    return False


def scan_bytes(data: bytes, personal, path: str = ""):
    """Yield (rule id, severity, fingerprint) for every unallowed hit in one blob."""
    if b"\x00" in data[:8192]:
        return                                   # binary: images have their own pass
    for rid, sev, rx, _desc in COMPILED:
        if (rid, path) in PATH_ALLOW:
            continue
        for m in rx.finditer(data):
            if not accept(rid, m, data):
                yield rid, sev, fingerprint(m.group(0))
    low = data
    for kind, _term, rx in personal:
        for m in rx.finditer(low):
            yield "personal:" + kind, "medium", fingerprint(m.group(0).lower())


def git(*args, text=True, cwd=ROOT):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=text, check=True).stdout


class Report:
    def __init__(self):
        self.groups = collections.defaultdict(lambda: {"count": 0, "fingerprints": set(), "paths": collections.Counter()})
        self.scanned = 0
        self.skipped = 0
    def add(self, rid, sev, fp, path):
        g = self.groups[(rid, sev)]
        g["count"] += 1; g["fingerprints"].add(fp); g["paths"][path] += 1
    def summary(self):
        out = []
        for (rid, sev), g in sorted(self.groups.items(), key=lambda kv: (-SEVERITY[kv[0][1]], kv[0][0])):
            out.append({"rule": rid, "severity": sev, "occurrences": g["count"], "distinct_values": len(g["fingerprints"]), "files": len(g["paths"]),
                        "top_paths": [p for p, _ in g["paths"].most_common(5)]})
        return out
    def worst(self):
        return max((SEVERITY[sev] for (_r, sev) in self.groups), default=-1)


MAX_BLOB = 24 * 1024 * 1024


def scan_tree(personal):
    if not (ROOT / ".git").exists():          # a snapshot or an export has no git metadata: scan the directory instead
        return scan_directory(ROOT, personal)
    report = Report()
    for rel in git("ls-files", "-z").split("\0"):
        if not rel:
            continue
        path = ROOT / rel
        try:
            if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BLOB:
                report.skipped += 1; continue
            data = path.read_bytes()
        except OSError:
            report.skipped += 1; continue
        report.scanned += 1
        for rid, sev, fp in scan_bytes(data, personal, rel):
            report.add(rid, sev, fp, rel)
    return report


def scan_directory(directory, personal):
    """A plain directory (for example the public snapshot): every regular file, no git needed."""
    report = Report()
    base = Path(directory).resolve()
    for path in sorted(base.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        rel = str(path.relative_to(base))
        if {".build", "DerivedData", ".git", ".swiftpm"} & set(path.relative_to(base).parts):
            continue                                   # regenerable build output, never part of a source snapshot
        if path.stat().st_size > MAX_BLOB:
            report.skipped += 1; continue
        data = path.read_bytes()
        report.scanned += 1
        for rid, sev, fp in scan_bytes(data, personal, rel):
            report.add(rid, sev, fp, rel)
        if rel.lower().endswith(IMAGE_EXT):
            for rid, sev, fp in scan_bytes(png_text(data), personal):
                report.add("image-metadata:" + rid, sev, fp, rel)
    return report


def scan_history(personal):
    """Every blob reachable from any ref, each once, with the first path it was seen under, plus every commit's author, committer and message."""
    report = Report()
    listing = subprocess.run(["git", "rev-list", "--objects", "--all"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.splitlines()
    wanted = {}
    for line in listing:
        sha, _, name = line.partition(" ")
        wanted.setdefault(sha, name)
    proc = subprocess.Popen(["git", "cat-file", "--batch"], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    def read_object(sha):
        proc.stdin.write(sha.encode() + b"\n"); proc.stdin.flush()
        header = proc.stdout.readline().split()
        if len(header) < 3:
            return None, None
        kind, size = header[1], int(header[2])
        body = proc.stdout.read(size); proc.stdout.read(1)
        return kind, body
    for sha, name in wanted.items():
        kind, body = read_object(sha)
        if kind != b"blob":
            continue
        if len(body) > MAX_BLOB:
            report.skipped += 1; continue
        report.scanned += 1
        for rid, sev, fp in scan_bytes(body, personal, name or ""):
            report.add(rid, sev, fp, name or sha[:10])
    proc.stdin.close(); proc.wait()
    log = subprocess.run(["git", "log", "--all", "--format=%an%n%ae%n%cn%n%ce%n%B%x00"], cwd=ROOT, capture_output=True, check=True).stdout
    for chunk in log.split(b"\0"):
        for rid, sev, fp in scan_bytes(chunk, personal):
            report.add(rid, sev, fp, "(commit metadata)")
    return report


# ---- images -----------------------------------------------------------------------------------------------------------------------------------

PNG = b"\x89PNG\r\n\x1a\n"
TEXT_CHUNKS = {b"tEXt", b"zTXt", b"iTXt", b"eXIf"}


def png_text(data: bytes):
    """The text-bearing chunks of a PNG (author, software, comment, EXIF): where a screenshot tool can leave a path or a name."""
    if not data.startswith(PNG):
        return b""
    pos, out = 8, bytearray()
    while pos + 8 <= len(data):
        length = int.from_bytes(data[pos:pos + 4], "big"); kind = data[pos + 4:pos + 8]
        if kind in TEXT_CHUNKS:
            out += data[pos + 8: pos + 8 + length] + b"\n"
        pos += 12 + length
        if kind == b"IEND":
            break
    return bytes(out)


IMAGE_EXT = (".png", ".jpg", ".jpeg", ".heic", ".gif", ".tiff")


def tracked_images():
    return [r for r in git("ls-files", "-z").split("\0") if r.lower().endswith(IMAGE_EXT) and "Assets.xcassets" not in r and ".iconset/" not in r and "/Brand/" not in r]


def scan_images(personal, ocr=True):
    report = Report()
    images = tracked_images()
    for rel in images:
        data = (ROOT / rel).read_bytes() if (ROOT / rel).is_file() else b""
        report.scanned += 1
        for rid, sev, fp in scan_bytes(png_text(data) or b"", personal):
            report.add("image-metadata:" + rid, sev, fp, rel)
    if ocr and images:
        with tempfile.TemporaryDirectory() as tmp:
            listing = Path(tmp) / "images.txt"
            listing.write_text("\n".join(str(ROOT / r) for r in images))
            out = subprocess.run(["swift", str(ROOT / "scripts/ocr-images.swift"), str(listing)], capture_output=True, text=True, cwd=tmp)
            if out.returncode != 0:
                print("OCR unavailable:", out.stderr.strip()[:300], file=sys.stderr)
                report.add("ocr-unavailable", "low", "0", "(images)")
            else:
                for line in out.stdout.splitlines():
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    rel = os.path.relpath(entry["path"], ROOT)
                    for rid, sev, fp in scan_bytes(entry["text"].encode(), personal):
                        report.add("image-text:" + rid, sev, fp, rel)
    return report


# ---- self test ----------------------------------------------------------------------------------------------------------------------------------

def self_test():
    """Each rule must catch a planted sample and must pass its clean control; the allowlist must not swallow a real one."""
    def hits(text, personal=()):
        return {rid for rid, _s, _f in scan_bytes(text.encode(), compile_personal({t: "x" for t in personal}))}
    planted = {
        "google-session-cookie": "Cookie: __Secure-3PAPISID=" + "a1B2c3D4e5F6g7H8i9J0k1L2m3N4o5P6",
        "authorization-header": "Authorization: Bearer " + "abcdefghij0123456789ABCDEFGHIJ",
        "sapisidhash": "SAPISIDHASH 1699999999_" + "0123456789abcdef0123456789abcdef01234567",
        "google-access-token": "token ya29." + "A0ARrdaM-abcdefghijklmnopqrstuvwxyz0123",
        "google-refresh-token": "1//0" + "gAbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
        "google-client-secret": "GOCSPX-" + "abcdefghijklmnopqrstuvwxyz01",
        "google-api-key": "key=AIza" + "Sy" + "A" * 33,
        "jwt": "eyJhbGciOiJIUzI1NiJ9." + "eyJzdWIiOiIxMjM0NTY3ODkwIn0." + "abcdefghijklmnop",
        "private-key": "-----BEGIN " + "PRIVATE KEY-----",
        "github-token": "ghp_" + "a" * 36,
        "cloud-key": "AKIA" + "ABCDEFGHIJKLMNOP",
        "secret-assignment": 'client_secret = "' + "q" * 24 + '"',
        "team-id-setting": "DEVELOPMENT_TEAM = " + "Q7R8S9T0U1",
        "team-id-codesign": "TeamIdentifier=" + "Q7R8S9T0U1",
        "team-id-identity": "Developer ID Application: Some Person (" + "Q7R8S9T0U1" + ")",
        "team-id-app-group": "Q7R8S9T0U1" + ".local.native-music.development",
        "team-id-requirement": 'certificate leaf[subject.OU] = "' + 'Q7R8S9T0U1"',
        "email": "contact: someone.real" + "@gmail.com",
        "home-path": "/Users/" + "somebody" + "/Library",
        "anonymous-visitor-id": "visitorData: " + "CgtBYmNkZWZnaGlqa2w",
    }
    failures = []
    for rid, sample in planted.items():
        if rid not in hits(sample):
            failures.append(f"rule {rid} missed its planted sample")
    clean = [
        "DEVELOPMENT_TEAM = $(YTMUSE_TEAM)", "DEVELOPMENT_TEAM = XXXXXXXXXX", "$(TeamIdentifierPrefix)local.native-music.development", "icon_16x16@2x.png",
        "noreply@anthropic.com", "someone@example.com", "/Users/Shared/", "/Users/<you>/Projects", "Authorization: Bearer <redacted-token-value-here>",
        "key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30", "the quick brown fox", "SAPISID is a cookie name, never its value", "TeamIdentifier=SYNTH12345", "SAPISIDHASH 1700000000_" + "0123456789abcdef0123456789abcdef01234567", "pw@music.youtube.com",
    ]
    for text in clean:
        if hits(text):
            failures.append(f"clean control flagged: {text!r} -> {sorted(hits(text))}")
    # personal terms are matched case-insensitively and not printed
    if "personal:x" not in hits("see /home/Jane-Q-Public/", personal=("jane-q-public",)):
        failures.append("personal term not matched")
    if "personal:x" in hits("nothing here", personal=("jane-q-public",)):
        failures.append("personal term false positive")
    # the PNG chunk reader sees a text chunk and ignores pixel data
    chunk = lambda kind, body: len(body).to_bytes(4, "big") + kind + body + b"\0\0\0\0"
    png = PNG + chunk(b"IHDR", b"\0" * 13) + chunk(b"tEXt", b"Comment\0/Users" + b"/somebody/Desktop/shot.png") + chunk(b"IDAT", b"/Users" + b"/hidden/in/pixels") + chunk(b"IEND", b"")
    if b"/Users" + b"/somebody/" not in png_text(png) or b"hidden" in png_text(png):
        failures.append("png chunk reader wrong")
    # the report never stores values
    r = Report(); r.add("email", "medium", fingerprint(b"a" + b"@b.cc"), "x.txt")
    if "a" + "@b.cc" in json.dumps(r.summary()):
        failures.append("report leaks a value")
    if failures:
        print("SELF-TEST FAILED:\n  " + "\n  ".join(failures)); return 1
    print(f"scan-repository self-test: ok ({len(planted)} rules caught, {len(clean)} clean controls passed)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true"); ap.add_argument("--tree", action="store_true"); ap.add_argument("--history", action="store_true")
    ap.add_argument("--tree-dir"); ap.add_argument("--images", action="store_true"); ap.add_argument("--no-ocr", action="store_true"); ap.add_argument("--json"); ap.add_argument("--fail-on", choices=list(SEVERITY))
    ap.add_argument("--personal-term", action="append", default=[])
    args = ap.parse_args()
    if args.self_test:
        sys.exit(self_test())
    personal = compile_personal(personal_terms(args.personal_term))
    result = {}
    worst = -1
    for name, enabled, fn in (("tree", args.tree, lambda: scan_tree(personal)), ("tree-dir", bool(args.tree_dir), lambda: scan_directory(args.tree_dir, personal)), ("history", args.history, lambda: scan_history(personal)),
                              ("images", args.images, lambda: scan_images(personal, ocr=not args.no_ocr))):
        if not enabled:
            continue
        report = fn()
        result[name] = {"scanned": report.scanned, "skipped": report.skipped, "findings": report.summary()}
        worst = max(worst, report.worst())
        print(f"[{name}] scanned {report.scanned} (skipped {report.skipped}); {len(report.groups)} finding groups")
        for f in report.summary():
            print(f"  {f['severity']:6} {f['rule']:34} {f['occurrences']:>7} hits, {f['distinct_values']:>5} values, {f['files']:>5} files   e.g. {f['top_paths'][0]}")
    if args.json:
        Path(args.json).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    if args.fail_on and worst >= SEVERITY[args.fail_on]:
        sys.exit(1)


if __name__ == "__main__":
    main()
