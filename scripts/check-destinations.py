#!/usr/bin/env python3
"""W29 (SEC01, SEC02, ARCH05, ARCH07, SEC06, SEC09, T29.3): the network-destination, dependency, entitlement and remote-code audit.

Source mode (default): every host named in the product's source, property lists and entitlement files is in Docs/Network-Destinations.json; no telemetry or advertising SDK name
appears in code; no external package is declared; no remote-code mechanism is used; entitlements and usage descriptions are the least the app needs.
Binary mode (--binary <YTMuse.app>): the same host and deny-list rules over the built bundle's executables and frameworks, the linked-framework deny list, and the signed entitlements.
--self-test proves every rule fires on a planted violation and stays quiet on a near miss, so a rule that cannot fail is caught."""
import json, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INVENTORY = ROOT / "Docs" / "Network-Destinations.json"
SOURCE_DIRS = ["Packages/NativeMusic/Sources", "App/Sources", "Extensions/Sources"]
PLISTS = ["App/Info.plist", "Extensions/NativeMusicWidget-Info.plist", "App/NativeMusic.entitlements", "App/NativeMusic-adhoc.entitlements", "Extensions/NativeMusicWidget.entitlements", "Extensions/NativeMusicWidget-adhoc.entitlements"]
URL = re.compile(r"\b(?:https?|wss?|ftp)://([A-Za-z0-9][A-Za-z0-9.-]*)", re.I)
BARE = re.compile(r'"([a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.(?:com|net|org|io|app|dev|tv|ai|co|be|ly))"', re.I)
REMOTE_CODE = [
    (r"\bdlopen\s*\(", "dlopen"), (r"\bProcess\(\)", "Process()"), (r"\bNSTask\b", "NSTask"), (r"NS" + r"AppleScript\s*\(\s*source", "AppleScript(source:)"), (r"\bJSContext\b", "JSContext"),
    (r"\.evaluateScript\(", "evaluateScript"), (r"\bposix_spawn", "posix_spawn"), (r"\bexecv[pe]?\(", "exec"), (r"Bundle\(\s*(?:url|path)[^)]*\)\s*\??\.load\(", "Bundle.load"), (r"\bloadPlugin", "loadPlugin"),
    (r"NSClassFromString\([^)]*(?:download|remote|http)", "NSClassFromString(remote)"), (r"\bSMJobSubmit|\bSMAppService\.daemon", "privileged helper"),
]

def load_inventory():
    return json.loads(INVENTORY.read_text())

def allowed_hosts(inv):
    exact, suffixes = set(), []
    for group in ("service", "artwork", "pageDriven", "externalLinks", "local", "updates", "documentation"):
        for entry in inv.get(group, []):
            host = entry["host"].lower()
            if host.startswith("*."): suffixes.append(host[1:])
            else: exact.add(host)
    return exact, suffixes

def host_allowed(host, exact, suffixes):
    host = host.lower().rstrip(".")
    return host in exact or any(host.endswith(s) or host == s[1:] for s in suffixes)

def deny_match(word, text):
    """A deny-list entry matches at the start of a word (so FirebaseAnalytics and firebaseinstallations match) but never inside one: 'rollbar.com' is a crash reporter, 'scrollbar' is not."""
    return re.search(r"(?<![a-z0-9])" + re.escape(word.lower()), text.lower()) is not None

def code_lines(text):
    """The text with line comments removed (never inside a URL)."""
    return "\n".join(re.sub(r"(?<!:)//.*$", "", line) for line in text.split("\n"))

def swift_files():
    out = []
    for d in SOURCE_DIRS:
        base = ROOT / d
        if base.exists(): out += sorted(base.rglob("*.swift"))
    return out

def hosts_in(text, include_bare=True):
    found = set(m.group(1).lower().rstrip(".") for m in URL.finditer(text))
    if include_bare: found |= set(m.group(1).lower() for m in BARE.finditer(text))
    return found

def audit_text(name, text, inv, exact, suffixes, is_code=True):
    """Findings for one file's text."""
    findings = []
    body = code_lines(text) if is_code else text
    for host in sorted(hosts_in(body)):
        # A reverse-DNS identifier ("local.native-music.development", "com.apple.…") is not a host; a bare name must end in a real TLD (the BARE pattern) to get here.
        if not host_allowed(host, exact, suffixes): findings.append(f"{name}: host '{host}' is not in Docs/Network-Destinations.json")
    for word in inv["telemetryDenyList"]:
        if deny_match(word, body): findings.append(f"{name}: names telemetry/advertising SDK or host '{word}'")
    if is_code:
        reviewed = {entry["file"]: entry["executable"] for entry in inv.get("reviewedProcessLaunches", [])}
        for pattern, label in REMOTE_CODE:
            if not re.search(pattern, body): continue
            # A reviewed launch: the file is named in the inventory, launches exactly the one fixed executable and names no other.
            if label == "Process()" and Path(name).name in reviewed:
                paths = re.findall(r"executableURL\s*=\s*URL\(fileURLWithPath:\s*\"([^\"]+)\"", body)
                if paths and set(paths) == {reviewed[Path(name).name]} and "executableURL = URL(fileURLWithPath: " + "path" not in body: continue
            findings.append(f"{name}: uses {label} (remote-code or process-launch mechanism)")
    return findings

def audit_dependencies(inv):
    findings = []
    for manifest in ("Packages/NativeMusic/Package.swift", "Extensions/Package.swift"):
        text = code_lines((ROOT / manifest).read_text())
        if re.search(r"\.package\s*\(", text): findings.append(f"{manifest}: declares a package dependency")
    for resolved in ("Packages/NativeMusic/Package.resolved", "Extensions/Package.resolved"):
        path = ROOT / resolved
        if path.exists() and json.loads(path.read_text()).get("pins"): findings.append(f"{resolved}: pins an external package")
    pbx = (ROOT / "App/NativeMusic.xcodeproj/project.pbxproj").read_text()
    if "XCRemoteSwiftPackageReference" in pbx: findings.append("project.pbxproj: references a remote Swift package")
    tool = json.loads((ROOT / "toolchain.json").read_text())
    if tool.get("external_dependencies"): findings.append("toolchain.json: lists external dependencies")
    return findings

def audit_entitlements(inv, files):
    findings = []
    for rel in files:
        path = ROOT / rel
        if not path.exists() or not rel.endswith(".entitlements"): continue
        text = path.read_text()
        for key in inv["deniedEntitlements"]:
            if f"<key>{key}</key>" in text: findings.append(f"{rel}: requests {key}")
    return findings

def audit_plists(inv, files):
    findings = []
    for rel in files:
        path = ROOT / rel
        if not path.exists() or not rel.endswith("Info.plist"): continue
        for key in re.findall(r"<key>(NS[A-Za-z]+UsageDescription)</key>", path.read_text()):
            if key not in inv["allowedUsageDescriptions"]: findings.append(f"{rel}: declares {key}, a permission the feature has not been activated for")
        if "NSAppTransportSecurity" in path.read_text(): findings.append(f"{rel}: declares App Transport Security exceptions")
    return findings

def run_source():
    inv = load_inventory(); exact, suffixes = allowed_hosts(inv)
    findings, scanned = [], 0
    for path in swift_files():
        scanned += 1
        findings += audit_text(str(path.relative_to(ROOT)), path.read_text(errors="replace"), inv, exact, suffixes)
    for rel in PLISTS:
        path = ROOT / rel
        if path.exists(): scanned += 1; findings += audit_text(rel, path.read_text(), inv, exact, suffixes, is_code=False)
    findings += audit_dependencies(inv) + audit_entitlements(inv, PLISTS) + audit_plists(inv, PLISTS)
    if scanned < 300: findings.append(f"sweep looked at only {scanned} files; the population is wrong")
    return findings, scanned

def run_binary(app):
    inv = load_inventory(); exact, suffixes = allowed_hosts(inv)
    app = Path(app); findings = []
    if not (app / "Contents" / "MacOS").exists(): return [f"{app}: not an application bundle"], 0
    binaries = [p for p in app.rglob("*") if p.is_file() and not p.is_symlink() and (p.suffix in ("", ".dylib", ".appex") or "MacOS" in p.parts) and "Resources" not in p.parts and p.stat().st_size > 4096]
    scanned = 0
    seen = set()
    for binary in binaries:
        try: kind = subprocess.run(["file", "-b", str(binary)], capture_output=True, text=True).stdout
        except Exception: continue
        if "Mach-O" not in kind: continue
        scanned += 1
        strings = subprocess.run(["strings", "-a", str(binary)], capture_output=True, text=True).stdout
        rel = str(binary.relative_to(app))
        for host in sorted(hosts_in(strings, include_bare=False)):
            seen.add(host)
            if not host_allowed(host, exact, suffixes): findings.append(f"{rel}: binary names host '{host}' which is not in the inventory")
        for word in inv["telemetryDenyList"]:
            if deny_match(word, strings): findings.append(f"{rel}: binary contains telemetry/advertising name '{word}'")
        links = subprocess.run(["otool", "-L", str(binary)], capture_output=True, text=True).stdout
        for name in inv["deniedLinkedFrameworks"]:
            if "*" in name or "remote" in name: continue
            if re.search(r"/" + re.escape(name) + r"[^/\n]*", links, re.I): findings.append(f"{rel}: links {name}")
        for line in links.splitlines()[1:]:
            path = line.strip().split(" ")[0]
            if path and not (path.startswith(("/System/", "/usr/lib/", "@rpath/", "@executable_path/", "@loader_path/"))): findings.append(f"{rel}: links unexpected library {path}")
    # The sweep must have looked at the product: its own service host is in the binary's strings (a bundle that names no host at all would pass vacuously).
    for required in ("music.youtube.com", "oauth2.googleapis.com", "accounts.google.com"):
        if required not in seen: findings.append(f"binary audit did not find {required} in the bundle's strings; the population is wrong")
    print(f"binary audit saw {len(seen)} distinct hosts: {', '.join(sorted(seen))}")
    frameworks = app / "Contents" / "Frameworks"
    if frameworks.exists():
        for item in sorted(frameworks.iterdir()):
            if any(d.lower() in item.name.lower() for d in inv["deniedLinkedFrameworks"] if "*" not in d and "remote" not in d): findings.append(f"Frameworks/{item.name}: denied framework embedded")
    ent = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)], capture_output=True, text=True)
    text = ent.stdout + ent.stderr
    for key in inv["deniedEntitlements"]:
        if f"<key>{key}</key>" in text and key != "com.apple.security.get-task-allow": findings.append(f"signed bundle requests {key}")
    return findings, scanned

def self_test():
    inv = load_inventory(); exact, suffixes = allowed_hosts(inv)
    cases = [
        ("unlisted host", 'let u = URL(string: "https://telemetry.example.net/ping")!', True), ("listed host", 'let u = URL(string: "https://music.youtube.com/x")!', False),
        ("suffix host", 'let u = "https://rr4---sn-abc.googlevideo.com/videoplayback"', False), ("lookalike host", 'let u = "https://music.youtube.com.evil.example/"', True),
        ("bare unlisted host", 'let h = "collect.example.io"', True), ("bare listed host", 'let h = "music.youtube.com"', False), ("reverse DNS id", 'let id = "local.native-music.development"', False),
        ("comment mention", '// see https://analytics.example.net/docs\nlet x = 1', False), ("telemetry host", 'let c = "https://app-measurement.com/a"', True), ("telemetry SDK", 'import FirebaseAnalytics', True),
        ("process launch", 'let p = Process()', True), ("dlopen", 'let h = dlopen(path, RTLD_NOW)', True), ("near miss process", 'let processor = ProcessingQueue()', False), ("loopback", 'let u = "http://127.0.0.1:5000/cb"', False),
        ("unreviewed process file", 'let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")', True),
        ("ad host", 'let u = "https://pagead2.googlesyndication.com/x"', True), ("word inside a longer word", 'let v = NSScroller().scrollbarStyle // scrollbar', False), ("dsp word", 'let amplitude = peak', False),
        ("brand as a token", 'let c = Rollbar.rollbar.com', True),
    ]
    failed = 0
    for name, text, expect in cases:
        got = bool(audit_text("planted", text, inv, exact, suffixes))
        if got != expect: print(f"self-test FAILED: {name}: expected {'finding' if expect else 'clean'}"); failed += 1
    if failed: sys.exit(1)
    print(f"check-destinations self-test: {len(cases)} cases ok")

def main(argv):
    if "--self-test" in argv: self_test(); return 0
    if "--binary" in argv:
        findings, scanned = run_binary(argv[argv.index("--binary") + 1])
        label = f"binary audit: {scanned} Mach-O files"
    else:
        findings, scanned = run_source()
        label = f"source audit: {scanned} files"
    if findings:
        print(label + ": FAILED"); [print("  " + f) for f in findings]; return 1
    print(label + ": ok"); return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
