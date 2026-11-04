#!/usr/bin/env python3
"""BUILD04 / T30.4: the software bill of materials, CycloneDX 1.5 JSON, generated from the repository and deterministic (no clock, no random id).

  make-sbom.py --out Docs/sbom.cdx.json     write it
  make-sbom.py --check Docs/sbom.cdx.json   fail when the checked-in file is not what the repository now produces

What it lists: the application, its first-party modules (from the reviewed module graph), the build toolchain (from toolchain.json), the system
frameworks the sources import (provided by macOS, never shipped), and the third-party material recorded in THIRD_PARTY_NOTICES.md. External packages: none.
The hidden YouTube Music player is the system WebKit, which is part of the operating system.
"""
import argparse, hashlib, json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION_RX = re.compile(r"MARKETING_VERSION = ([0-9][0-9A-Za-z.\-]*);")
SOURCE_DIRS = ["App/Sources", "Extensions/Sources", "Packages/NativeMusic/Sources"]
# Each material that is not first-party code, with the licence the notices file records. Keep in step with THIRD_PARTY_NOTICES.md (check-distribution.py enforces it).
THIRD_PARTY = [
    {"name": "Kaset", "version": "4c59ff259d853f1cc328597f5adccf2a291c2fa7", "type": "data", "license": "MIT", "copyright": "Copyright (c) 2025 sozercan",
     "url": "https://github.com/sozercan/kaset",
     "note": "Two test fixtures copied byte-for-byte (Fixtures/W12-kaset-real, Fixtures/W13-real) and parsing conventions re-implemented in original code. Nothing is linked or shipped in the app."},
    {"name": "ytmusicapi", "version": "4da34b68e68d33356860fbf5d4f0245655969b08", "type": "data", "license": "MIT", "copyright": "See the upstream repository's licence file (it was not captured with the copy)",
     "url": "https://github.com/sigma67/ytmusicapi",
     "note": "A pinned reference copy of two upstream files (artifacts/harness/nodes/W19/reference), retained only as historical review evidence after removal of the upload feature. Nothing is linked, shipped or copied into product code."},
]


def swift_imports():
    names = set()
    for d in SOURCE_DIRS:
        for p in (ROOT / d).rglob("*.swift"):
            for m in re.finditer(r"^(?:@preconcurrency\s+|@_exported\s+|@testable\s+)?import\s+(?:struct\s+|class\s+|enum\s+|protocol\s+|func\s+|var\s+|typealias\s+)?([A-Za-z_][A-Za-z0-9_]*)", p.read_text(errors="ignore"), re.M):
                names.add(m.group(1))
    return names


def build():
    modules = json.loads((ROOT / "scripts/module-dependencies.json").read_text())
    toolchain = json.loads((ROOT / "toolchain.json").read_text())
    project = (ROOT / "App/NativeMusic.xcodeproj/project.pbxproj").read_text()
    version = (VERSION_RX.search(project) or [None, "0.0.0"])[1]
    first_party = set(modules) | {"AppShell", "FeedTool"}
    system = sorted(n for n in swift_imports() if n not in first_party and n not in {"XCTest", "Testing"})
    components = [{
        "bom-ref": "ytmuse-app", "type": "application", "name": "YTMuse", "version": version, "licenses": [{"license": {"id": "MIT"}}],
        "description": "Independent native YouTube Music client for macOS. Original code.", "scope": "required",
    }]
    for name in sorted(modules):
        components.append({"bom-ref": f"module-{name}", "type": "library", "name": name, "version": version, "scope": "required", "licenses": [{"license": {"id": "MIT"}}],
                           "properties": [{"name": "ytmuse:origin", "value": "first-party Swift package target (Packages/NativeMusic)"}]})
    components.append({"bom-ref": "tool-feed", "type": "application", "name": "FeedTool", "version": version, "scope": "excluded", "licenses": [{"license": {"id": "MIT"}}],
                       "properties": [{"name": "ytmuse:origin", "value": "release tooling (ytmuse-feed); not part of the app bundle"}]})
    for tool, key in (("Xcode", "xcode"), ("Swift", "swift"), ("macOS SDK", "macos_sdk")):
        components.append({"bom-ref": "build-" + tool.lower().replace(" ", "-"), "type": "application" if tool != "macOS SDK" else "platform", "name": tool, "version": str(toolchain[key]),
                           "scope": "excluded", "supplier": {"name": "Apple Inc."}, "licenses": [{"license": {"name": "Apple Xcode and SDK licence agreements (build tool; not redistributed)"}}],
                           "properties": [{"name": "ytmuse:role", "value": "build toolchain"}]})
    for name in system:
        components.append({"bom-ref": "system-" + name, "type": "framework", "name": name, "scope": "required", "supplier": {"name": "Apple Inc."},
                           "licenses": [{"license": {"name": "Part of macOS; provided by the operating system and not redistributed"}}],
                           "properties": [{"name": "ytmuse:distribution", "value": "operating-system"}]})
    for item in THIRD_PARTY:
        components.append({"bom-ref": "third-party-" + item["name"].lower(), "type": item["type"], "name": item["name"], "version": item["version"], "scope": "excluded",
                           "copyright": item["copyright"], "licenses": [{"license": {"id": item["license"]}}], "externalReferences": [{"type": "vcs", "url": item["url"]}],
                           "properties": [{"name": "ytmuse:use", "value": item["note"]}]})
    app_modules = ["module-AppShell", "module-SystemIntegration", "module-WidgetShared", "module-YouTubeMusicAdapter"]   # the app target's package products (scripts/generate-project.py)
    dependencies = [{"ref": "ytmuse-app", "dependsOn": sorted(app_modules + ["system-" + n for n in system])}]
    for name in sorted(modules):
        dependencies.append({"ref": "module-" + name, "dependsOn": sorted("module-" + d for d in modules[name])})
    body = {
        "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
        "metadata": {"component": components[0], "tools": {"components": [{"type": "application", "name": "scripts/make-sbom.py"}]},
                     "properties": [
                         {"name": "ytmuse:external-packages", "value": "0"},
                         {"name": "ytmuse:bundled-runtimes", "value": "none (no Python, Node, browser engine or remote executable adapter)"},
                         {"name": "ytmuse:hidden-player", "value": "The hidden YouTube Music player is the system WebKit (WKWebView), part of macOS and not shipped in the app."},
                         {"name": "ytmuse:architecture", "value": toolchain["architecture"]}]},
        "components": components[1:], "dependencies": dependencies,
    }
    text = json.dumps(body, indent=2, sort_keys=True) + "\n"
    body["serialNumber"] = "urn:uuid:" + str(__import__("uuid").UUID(hashlib.sha256(text.encode()).hexdigest()[:32]))   # content-derived, so the file is reproducible
    return json.dumps(body, indent=2, sort_keys=True) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out"); ap.add_argument("--check")
    args = ap.parse_args()
    text = build()
    if args.out:
        Path(args.out).write_text(text); print(f"wrote {args.out} ({len(text)} bytes)")
    if args.check:
        current = Path(args.check).read_text() if Path(args.check).exists() else ""
        if current != text:
            print(f"{args.check} is stale or missing: run scripts/make-sbom.py --out {args.check}", file=sys.stderr); sys.exit(1)
        print(f"sbom up to date: {args.check}")
    if not args.out and not args.check:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
