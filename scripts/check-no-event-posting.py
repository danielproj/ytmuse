#!/usr/bin/env python3
"""W44-prep (critic round 2, L-a): UI and test sources never post synthetic input events themselves.

A test that posts a raw CGEvent (HID tap, to a pid, a warped cursor) needs the Accessibility/PostEvent permission the runner does not hold, can reach an
application other than the one under test, and raised the system's "control this computer using accessibility features" prompt over the test area. XCTest's own
actions (`XCUIElement.click`, `scroll`, `typeText`) address and activate the app under test and need none of that.

  check-no-event-posting.py            sweep Tests/ and Packages/NativeMusic/Tests/ (fails on a hit)
  check-no-event-posting.py --self-test  a planted hit per pattern and a clean control, in a temporary directory
Line comments are ignored (they may explain why the pattern is forbidden); the sweep requires a non-empty population.
"""
import pathlib, re, sys, tempfile

PATTERNS = {
    "CGEvent post": r"\bCGEvent\b[^\n]*\.post\(|\bCGEventPost\b",
    "HID event tap": r"\bcghidEventTap\b|\bcgSessionEventTap\b|\bcgAnnotatedSessionEventTap\b",
    "post to pid": r"\bpostToPid\b|\bCGEventPostToPid\b",
    "post to PSN": r"\bCGEventPostToPSN\b|\bpostToPSN\b",
    "accessibility key post": r"\bAXUIElementPostKeyboardEvent\b",
    "IOHID post": r"\bIOHIDPostEvent\b",
    "cursor warp": r"\bCGWarpMouseCursorPosition\b|\bCGDisplayMoveCursorToPoint\b",
    "tap-based post": r"\.post\(\s*tap:",
}
ROOTS = ["Tests", "Packages/NativeMusic/Tests"]
SUFFIXES = {".swift", ".m", ".mm", ".c"}
# Documented limit: a name assembled from string pieces and resolved at run time (`dlsym`, `NSSelectorFromString`) is not seen. This sweep is a regression net
# for the forms that existed, not a safety boundary: the runner holds no PostEvent permission, and XCTest's own actions are the supported path.


def code(text):
    """Source with comments removed, aware of string literals (a `//` inside "https://…" does not start a comment and cannot hide a call after it)."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':                       # a string literal (escapes honoured); its content is kept, so a name inside a literal is still visible
            j = i + 1
            while j < n and text[j] != '"' and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1]); i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j       # keep the newline
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, j)); i = j
        else:
            out.append(c); i += 1
    return "".join(out)


def offences(path, text):
    stripped = code(text)
    return [f"{path}: {name}" for name, pattern in PATTERNS.items() if re.search(pattern, stripped)]


def sweep(root):
    files = [p for r in ROOTS for p in (root / r).rglob("*") if p.suffix in SUFFIXES]
    found = []
    for path in files:
        found += offences(path.relative_to(root), path.read_text(errors="replace"))
    return files, found


def self_test():
    planted = [
        ("CGEvent post", "a.swift", "let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0); e?.post(tap: .cghidEventTap)"),
        ("HID event tap", "a.swift", "let tap = CGEventTapLocation.cghidEventTap"),
        ("post to pid", "a.swift", "event.postToPid(pid)"),
        ("post to PSN", "a.swift", "CGEventPostToPSN(&psn, event)"),
        ("post to PSN", "a.swift", "event.postToPSN(processSerialNumber: psn)"),
        ("accessibility key post", "a.swift", "AXUIElementPostKeyboardEvent(app, 0, 36, true)"),
        ("IOHID post", "a.swift", "IOHIDPostEvent(connect, 6, point, &data, 0, 0, 0)"),
        ("cursor warp", "a.swift", "CGWarpMouseCursorPosition(CGPoint(x: 1, y: 2))"),
        ("tap-based post", "a.swift", "someEvent.post(tap: location)"),
        ("CGEvent post", "Helper.m", "CGEventPost(kCGHIDEventTap, event);"),          # Objective-C
        ("post to PSN", "Helper.mm", "CGEventPostToPSN(&psn, event);"),               # Objective-C++
        ("post to pid", "helper.c", "CGEventPostToPid(pid, event);"),                  # C
        ("cursor warp", "b.swift", 'let u = "https://example.invalid/x"; CGWarpMouseCursorPosition(p)'),   # a // inside a string must not hide the call
        ("HID event tap", "c.swift", 'let s = "a//b"; let t = CGEventTapLocation.cghidEventTap /* c */'),
    ]
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        for r in ROOTS:
            (root / r).mkdir(parents=True)
        (root / ROOTS[0] / "Clean.swift").write_text("// uses CGEvent.post and cghidEventTap only in this sentence\nimport XCTest\nfunc f(_ w: XCUIElement) { w.scroll(byDeltaX: 0, deltaY: -10) }\n")
        files, found = sweep(root)
        assert files and not found, f"clean control must pass: {found}"
        for name, filename, source in planted:
            path = root / ROOTS[1] / filename
            path.write_text(source + "\n")
            _, found = sweep(root)
            assert any(name in f and filename in f for f in found), f"planted '{name}' in {filename} not detected: {found}"
            path.unlink()
        # comment handling: a pattern named only in comments passes, one after a comment on the line before does not
        (root / ROOTS[0] / "Clean.swift").write_text("/* CGEventPost in a block comment */\n// postToPid in a line comment\nlet url = \"https://x\" // CGWarpMouseCursorPosition\n")
        _, found = sweep(root)
        assert not found, f"comments must not trigger: {found}"
    print("check-no-event-posting self-test: ok")


def main():
    if "--self-test" in sys.argv:
        self_test()
        return 0
    root = pathlib.Path(__file__).resolve().parents[1]
    files, found = sweep(root)
    if len(files) < 50:
        print(f"check-no-event-posting: the sweep looked at only {len(files)} files", file=sys.stderr)
        return 1
    if found:
        print("check-no-event-posting FAILED:\n  " + "\n  ".join(found), file=sys.stderr)
        return 1
    print(f"check-no-event-posting: {len(files)} test sources, no synthetic event posting")
    return 0


if __name__ == "__main__":
    sys.exit(main())
