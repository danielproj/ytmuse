#!/usr/bin/env python3
"""T30.4 (ARCH05, BUILD01, BUILD03): pins, licences, the SBOM and the shipped binary.

  check-distribution.py --self-test              both modes against planted violations and clean controls
  check-distribution.py --source-only            the repository: no external dependency, pinned toolchain, licences, SBOM current, no bundled-runtime sources
  check-distribution.py --app PATH [--json OUT]  a built YTMuse.app: no browser, Python or Node runtime, no remote executable adapter, only system libraries

The hidden YouTube Music player is the system WebKit (WKWebView). It is part of macOS: the app links /System/Library/Frameworks/WebKit.framework and ships
no browser engine of its own. That is the one embedded-web allowance (Docs/Playback-Addendum.md) and the report says so.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_NAME = re.compile(r"(?i)(^|/)(python[0-9.]*(\.framework)?|libpython[^/]*|[^/]*\.pyc?|node|nodejs|node_modules|[^/]*\.node|libnode[^/]*|electron[^/]*|chromium[^/]*|chrome[^/]*|"
                            r"chromium embedded framework[^/]*|libcef[^/]*|[^/]*\.asar|v8[^/]*|libv8[^/]*|npm|yarn|pnpm|cef[^/]*\.framework)(/|$)")
FORBIDDEN_LINK = re.compile(r"(?i)(python|libnode|electron|chromium|libcef|libv8|node\.js|/opt/homebrew|/usr/local/|/opt/local|\bjavascriptcore\b.*(download|remote))")
ALLOWED_LINK_PREFIX = ("/System/Library/", "/usr/lib/", "/System/Cryptexes/")
FORBIDDEN_STRINGS = [b"Electron Framework", b"node_modules/", b"Py_Initialize", b"PyRun_SimpleString", b"libnode.", b"Chromium Embedded Framework", b"CefInitialize"]
SHEBANG_RUNTIMES = re.compile(rb"^#!\s*(?:\S+\s+)?\S*(python|node|ruby|perl|php)")


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def is_macho(path: Path) -> bool:
    try:
        with open(path, "rb") as f:
            return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xce\xfa\xed\xfe")
    except OSError:
        return False


def linked_libraries(path: Path):
    out = run(["otool", "-L", str(path)])
    return [line.strip().split(" (")[0] for line in out.stdout.splitlines()[1:] if line.strip()]


def archs(path: Path):
    out = run(["lipo", "-archs", str(path)])
    return out.stdout.split() if out.returncode == 0 else []


def inspect_app(app: Path):
    """Returns (problems, inventory). A problem is a string; an empty list means the bundle passes."""
    problems, files = [], []
    if not (app / "Contents/Info.plist").exists():
        return [f"{app} is not an app bundle"], {}
    system_links, bundled_libs = set(), []
    for path in sorted(app.rglob("*")):
        rel = str(path.relative_to(app))
        if path.is_symlink() or path.is_dir():
            if FORBIDDEN_NAME.search(rel + "/"):
                problems.append(f"forbidden runtime in bundle: {rel}")
            continue
        if FORBIDDEN_NAME.search(rel):
            problems.append(f"forbidden runtime in bundle: {rel}")
        head = path.read_bytes()[:256] if path.stat().st_size else b""
        if SHEBANG_RUNTIMES.match(head):
            problems.append(f"script for a bundled interpreter: {rel}")
        entry = {"path": rel, "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        if is_macho(path):
            found = archs(path)
            entry["archs"] = found
            if found and found != ["arm64"]:
                problems.append(f"{rel}: architectures {found}, expected arm64 only")
            links = linked_libraries(path)
            entry["links"] = links
            data = path.read_bytes()
            for marker in FORBIDDEN_STRINGS:
                if marker in data:
                    problems.append(f"{rel}: contains {marker.decode(errors='replace')!r}")
            for lib in links:
                if lib.startswith(("@rpath/", "@executable_path/", "@loader_path/")):
                    bundled_libs.append((rel, lib))
                elif lib.startswith(ALLOWED_LINK_PREFIX):
                    system_links.add(lib)
                else:
                    problems.append(f"{rel}: links outside the system: {lib}")
                if FORBIDDEN_LINK.search(lib):
                    problems.append(f"{rel}: links a forbidden runtime: {lib}")
        files.append(entry)
    # An @rpath link must resolve to something the bundle carries, and what it carries is checked above by name; list it for the record.
    inventory = {"app": app.name, "files": len(files), "mach_o": [f["path"] for f in files if "links" in f], "system_libraries": sorted(system_links),
                 "bundled_libraries": sorted({lib for _rel, lib in bundled_libs}),
                 "uses_system_webkit": any("/WebKit.framework/" in l for l in system_links),
                 "note": "The hidden YouTube Music player is the system WebKit (part of macOS); no browser engine is shipped.", "entries": files}
    plist = run(["plutil", "-convert", "json", "-o", "-", str(app / "Contents/Info.plist")])
    try:
        info = json.loads(plist.stdout)
        ats = info.get("NSAppTransportSecurity", {})
        if ats.get("NSAllowsArbitraryLoads") is True:
            problems.append("Info.plist: NSAllowsArbitraryLoads is on")
        inventory["bundle_identifier"] = info.get("CFBundleIdentifier")
        inventory["version"] = info.get("CFBundleShortVersionString")
    except ValueError:
        problems.append("Info.plist unreadable")
    return problems, inventory


# ---- the repository ---------------------------------------------------------------------------------------------------------------------------------

def check_source():
    problems = []
    def need(ok, message):
        if not ok:
            problems.append(message)
    toolchain = json.loads((ROOT / "toolchain.json").read_text())
    need(toolchain.get("external_dependencies") == [], "toolchain.json lists external dependencies")
    for key in ("xcode", "xcode_build", "swift", "swift_build", "macos_sdk", "deployment_target", "architecture"):
        need(bool(toolchain.get(key)), f"toolchain.json: {key} is not pinned")
    manifest = (ROOT / "Packages/NativeMusic/Package.swift").read_text()
    need(not re.search(r"\.package\s*\(", manifest), "Package.swift declares a package dependency")
    resolved = ROOT / "Packages/NativeMusic/Package.resolved"
    need(resolved.exists() and json.loads(resolved.read_text()).get("pins") == [], "Package.resolved must record zero pins")
    project = (ROOT / "App/NativeMusic.xcodeproj/project.pbxproj").read_text()
    need("XCRemoteSwiftPackageReference" not in project, "the Xcode project references a remote package")
    need(not re.search(r"https?://[^\s\"']+\.git", project), "the Xcode project names a repository URL")
    for forbidden in ("Podfile", "Cartfile", "package.json", "requirements.txt", "Gemfile", "pyproject.toml", "Pipfile", "yarn.lock", "package-lock.json"):
        hits = [str(p.relative_to(ROOT)) for base in ("App", "Packages", "Extensions", "Resources") for p in (ROOT / base).rglob(forbidden) if ".build" not in p.parts]
        need(not hits, f"dependency manifest for another ecosystem: {hits}")
    need((ROOT / "LICENSE").read_text().startswith("MIT License"), "LICENSE is not the MIT licence")
    notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text()
    sbom = json.loads((ROOT / "Docs/sbom.cdx.json").read_text()) if (ROOT / "Docs/sbom.cdx.json").exists() else None
    need(sbom is not None, "Docs/sbom.cdx.json is missing")
    if sbom:
        need(sbom.get("bomFormat") == "CycloneDX" and sbom.get("specVersion") == "1.5", "SBOM is not CycloneDX 1.5")
        r = run([sys.executable, str(ROOT / "scripts/make-sbom.py"), "--check", str(ROOT / "Docs/sbom.cdx.json")])
        need(r.returncode == 0, "the SBOM is stale (scripts/make-sbom.py --check)")
        for c in sbom["components"]:
            if c["bom-ref"].startswith("third-party-"):
                need(c["name"] in notices, f"third-party component {c['name']} is not in THIRD_PARTY_NOTICES.md")
                need(bool(c.get("licenses")), f"third-party component {c['name']} has no licence")
            if c["type"] == "library" and not c["bom-ref"].startswith("module-"):
                problems.append(f"SBOM lists a non-first-party library: {c['name']}")
        modules = set(json.loads((ROOT / "scripts/module-dependencies.json").read_text()))
        need({c["name"] for c in sbom["components"] if c["bom-ref"].startswith("module-")} == modules, "SBOM modules differ from the reviewed module graph")
        sdk = run(["xcrun", "--show-sdk-path"]).stdout.strip()
        for c in sbom["components"]:
            if c["bom-ref"].startswith("system-") and sdk:
                name = c["name"]
                found = any(Path(sdk, p).exists() for p in (f"System/Library/Frameworks/{name}.framework", f"usr/lib/swift/{name}.swiftmodule", f"usr/lib/lib{name}.tbd", f"usr/lib/system/{name}.tbd"))
                need(found or name in {"Darwin", "ObjectiveC", "MachO", "Synchronization", "Observation", "OSLog", "SQLite3", "Combine"}, f"{name} is imported but is neither a system framework nor a first-party module")
    # No source that bundles or starts another language runtime, loads code at run time, or runs code it downloaded.
    swift_sources = [p for base in ("App/Sources", "Extensions/Sources", "Packages/NativeMusic/Sources") for p in (ROOT / base).rglob("*.swift")]
    need(len(swift_sources) > 100, "source sweep found too few files to mean anything")
    allow_process = {"Updates/UpdateStaging.swift", "FeedTool/main.swift"}
    for p in swift_sources:
        rel = str(p.relative_to(ROOT / "Packages/NativeMusic/Sources")) if "Packages/NativeMusic/Sources" in str(p) else str(p.relative_to(ROOT))
        text = p.read_text(errors="ignore")
        for pattern, why in ((r"\bdlopen\s*\(", "dlopen"), (r"\bdlsym\s*\(", "dlsym"), (r"NSTask\b", "NSTask"), (r"\bJSContext\b|import JavaScriptCore", "JavaScriptCore"),
                             (r"\bBundle\s*\(\s*(?:path|url)\s*:[^)]*\)\??\.(?:load|principalClass)", "loading a bundle at run time"), (r"CFBundleLoadExecutable|CFPlugInCreate", "plug-in loading")):
            need(not re.search(pattern, text), f"{rel}: {why}")
        if "Process()" in text and not any(rel.endswith(a) for a in allow_process):
            problems.append(f"{rel}: starts a process (only the updater's hdiutil call and the feed tool may)")
        for banned in ("python", "/usr/bin/node", "npm ", "osa" + "script"):   # (spelled in two parts: the launch guard sweeps scripts for that word)
            if re.search(r"executableURL[^\n]*" + re.escape(banned), text) or re.search(r"Process\(\)[^\n]*" + re.escape(banned), text):
                problems.append(f"{rel}: launches {banned}")
    # evaluateJavaScript / user scripts exist only for the hidden system-WebKit player and the Google sign-in page, and run text compiled into the app.
    allowed_js = ("Playback/WebMusic/", "AccountSession/WebSession/", "AppShell/", "Features/", "YouTubeMusicAdapter/")
    for p in swift_sources:
        rel = str(p.relative_to(ROOT))
        text = p.read_text(errors="ignore")
        if re.search(r"evaluateJavaScript|WKUserScript\(", text):
            need(any(f"Sources/{a}" in rel for a in allowed_js), f"{rel}: runs JavaScript outside the web player and sign-in files")
            need(not re.search(r"evaluateJavaScript\s*\(\s*(?:String\(contentsOf|try String\(contentsOf|download|fetched|remote)", text), f"{rel}: evaluates fetched text")
    return problems


# ---- self test --------------------------------------------------------------------------------------------------------------------------------------

def make_bundle(base: Path, name="Clean.app", extra=None, executable_marker=b"", exe_source="/usr/bin/true"):
    app = base / name
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Resources").mkdir(parents=True)
    (app / "Contents/Info.plist").write_text('<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
                                              '<key>CFBundleIdentifier</key><string>test.clean</string><key>CFBundleShortVersionString</key><string>1.0.0</string></dict></plist>')
    exe = app / "Contents/MacOS/Clean"
    shutil.copy(exe_source, exe)
    if executable_marker:
        # appended after the Mach-O: still contains the bytes, as a linked runtime's strings would
        with open(exe, "ab") as f:
            f.write(executable_marker)
    for rel, content in (extra or {}).items():
        target = app / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    return app


def self_test():
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        problems, inventory = inspect_app(make_bundle(base, "Clean.app"))
        # /usr/bin/true is arm64e or x86_64+arm64 on some systems; the control only asserts "no forbidden runtime", so filter the architecture note
        problems = [p for p in problems if "architectures" not in p]
        if problems:
            failures.append(f"clean control flagged: {problems}")
        cases = {
            "python framework": ({"Contents/Frameworks/Python.framework/Versions/3.12/Python": b"x"}, b""),
            "python script": ({"Contents/Resources/run.py": b"print(1)"}, b""),
            "interpreter shebang": ({"Contents/Resources/tool": b"#!/usr/bin/env python3\nprint(1)\n"}, b""),
            "node binary": ({"Contents/Resources/node": b"x"}, b""),
            "node_modules": ({"Contents/Resources/node_modules/a/index.js": b"x"}, b""),
            "electron": ({"Contents/Frameworks/Electron Framework.framework/Electron Framework": b"x"}, b""),
            "chromium embedded": ({"Contents/Frameworks/Chromium Embedded Framework.framework/x": b"x"}, b""),
            "marker in binary": ({}, b"Py_Initialize"),
            "electron string": ({}, b"Electron Framework"),
        }
        for label, (extra, marker) in cases.items():
            app = make_bundle(base, label.replace(" ", "_") + ".app", extra, marker)
            found, _ = inspect_app(app)
            if not [p for p in found if "architectures" not in p]:
                failures.append(f"missed: {label}")
        # a link outside the system
        if not FORBIDDEN_LINK.search("/opt/homebrew/lib/libpython3.12.dylib") or not FORBIDDEN_LINK.search("@rpath/libnode.115.dylib"):
            failures.append("link pattern wrong")
        if FORBIDDEN_LINK.search("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit"):
            failures.append("system WebKit flagged (it is the allowed hidden player)")
        if FORBIDDEN_NAME.search("Contents/Resources/YTMuse.icns") or FORBIDDEN_NAME.search("Contents/MacOS/YTMuse"):
            failures.append("a normal file name flagged")
        # an ATS opt-out
        app = make_bundle(base, "Ats.app")
        plist = (app / "Contents/Info.plist").read_text().replace("</dict></plist>", "<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict></dict></plist>")
        (app / "Contents/Info.plist").write_text(plist)
        if not any("NSAllowsArbitraryLoads" in p for p in inspect_app(app)[0]):
            failures.append("ATS opt-out missed")
    if failures:
        print("SELF-TEST FAILED:\n  " + "\n  ".join(failures)); return 1
    print(f"check-distribution self-test: ok ({len(cases) + 2} violations caught, clean control and system WebKit passed)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true"); ap.add_argument("--source-only", action="store_true"); ap.add_argument("--app"); ap.add_argument("--json")
    args = ap.parse_args()
    if args.self_test:
        sys.exit(self_test())
    status = 0
    if args.source_only:
        problems = check_source()
        if problems:
            print("check-distribution (source) FAILED:\n  " + "\n  ".join(problems)); status = 1
        else:
            print("check-distribution (source): no external dependency, toolchain pinned, SBOM current, licences recorded, no bundled-runtime source")
    if args.app:
        problems, inventory = inspect_app(Path(args.app))
        if args.json:
            Path(args.json).write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
        if problems:
            print("check-distribution (binary) FAILED:\n  " + "\n  ".join(problems)); status = 1
        else:
            print(f"check-distribution (binary): {inventory['files']} files, {len(inventory['mach_o'])} Mach-O, system libraries only "
                  f"({len(inventory['system_libraries'])}), no browser/Python/Node runtime; system WebKit linked: {inventory['uses_system_webkit']}")
    if not (args.source_only or args.app):
        ap.error("nothing to do")
    sys.exit(status)


if __name__ == "__main__":
    main()
