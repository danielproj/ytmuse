#!/usr/bin/env python3
"""W23 (MAC02, T23.4): no global keyboard tap and no private accessory protocol.

Media keys and accessory buttons reach the app through MPRemoteCommandCenter only. This guard fails closed on:
  * sources: an event tap, a global event monitor, a system-defined (media key) event monitor, IOHID access, the private MediaRemote framework,
    dlopen/dlsym or private-framework paths;
  * entitlements: private entitlements, Mach-lookup exceptions for MediaRemote/HID services, HID entitlements;
  * linkage: MediaRemote or IOKit named in the package manifest or the Xcode project's linker settings;
  * binaries: undefined symbols, linked libraries and STRINGS of the forbidden kinds (a selector name such as addGlobalMonitorForEvents... is a string,
    not a symbol), in the SwiftPM object files of the app's own modules and in the built app and its dylibs.

What the binary layer cannot see: a name assembled at run time from pieces (a path or selector built by concatenation) leaves no whole string and no
symbol. Those are caught by the SOURCE layer, which bans the mechanisms that make them possible (Bundle(path:)/Bundle(url:), CFBundleCreate, dlopen,
dlsym, NSSelectorFromString) and scans Swift, Objective-C and C sources alike. A forbidden call reached through code that is neither in these sources
nor in a dependency's symbols is outside what any static guard can see; the app's entitlements and the live observations cover the rest.

Comments are not code: a sentence that names a forbidden API ("no event tap") is not a use of it. `--self-test` proves the guard flags each kind and
passes a clean tree, so a vacuous pass cannot hide behind a broken pattern.
"""
import plistlib, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SOURCE_PATTERNS = {
    'event tap': r'\bCGEventTap\w*|\bCGEvent\.tapCreate|\bkCGEventTap\w*|\bCGEventTapCreate\w*',
    'global event monitor': r'addGlobalMonitorForEvents\w*',
    'media-key (system-defined) monitor': r'\.systemDefined\b|\bNX_KEYTYPE\w*|\bNX_SYSDEFINED\b|\bNX_SUBTYPE\w*|\bNSSystemDefined\b',
    'IOHID access': r'\bIOHID\w*|\bimport\s+IOKit\.hid\b|\bIOHIDManager\w*',
    'private MediaRemote': r'\bMediaRemote\w*|\bMRMediaRemote\w*|\bMRNowPlaying\w*',
    'dynamic loading': r'\bdlopen\s*\(|\bdlsym\s*\(|\bBundle\s*\(\s*(?:path|url)\s*:|\bCFBundleCreate\w*|\bCFBundleGetBundleWithIdentifier\b|\bCFBundleGetFunctionPointer\w*|\bNSBundle\b',
    # A Swift Selector built from anything but a plain literal (a concatenation, a variable) can name any method; a literal one is still scanned for banned names.
    'dynamic selector': r'\bNSSelectorFromString\b|\bSelector\s*\((?!\s*\(*\s*"[^"\n]*"\s*\)*\s*\))',
    'private framework path': r'/System/Library/PrivateFrameworks|\bPrivateFrameworks\b',
}
# dlopen/dlsym are banned in OUR sources, not in the binary: Xcode's debug scaffolding (the stub that loads the .debug.dylib, previews) imports them.
BINARY_SYMBOLS = re.compile(r'_(CGEventTapCreate\w*|IOHID\w+|MRMediaRemote\w+|MRNowPlaying\w+|NSSelectorFromString|CFBundleGetFunctionPointer\w*|CFBundleGetBundleWithIdentifier|objc_msgSend\$addGlobalMonitorForEvents\w*)')
BINARY_STRINGS = re.compile(r'addGlobalMonitorForEvents\w*|MediaRemote|PrivateFrameworks|CGEventTapCreate\w*|IOHIDManager\w*|NX_SYSDEFINED')
BINARY_LIBRARIES = re.compile(r'MediaRemote\.framework|PrivateFrameworks')
SOURCE_EXTENSIONS = ('.swift', '.m', '.mm', '.c', '.h', '.cpp')
ENTITLEMENT_PRIVATE = re.compile(r'^com\.apple\.private\.|^com\.apple\.developer\.hid\.|^com\.apple\.security\.device\.(?:input|hid)')
MACH_LOOKUP = 'com.apple.security.temporary-exception.mach-lookup.global-name'
MACH_FORBIDDEN = re.compile(r'mediaremote|\bhid|HIDServer|iohid', re.I)
LINKAGE = re.compile(r'MediaRemote|\bIOKit\b|IOHID')


def strip_comments(text: str) -> str:
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    out = []
    for line in text.splitlines():
        # A // inside a string literal (a URL) is not a comment: only cut a // that is outside quotes.
        quoted, cut = False, len(line)
        for i, ch in enumerate(line):
            if ch == '"' and (i == 0 or line[i - 1] != '\\'): quoted = not quoted
            elif ch == '/' and not quoted and line[i:i + 2] == '//': cut = i; break
        out.append(line[:cut])
    return '\n'.join(out)


def scan_sources(roots):
    problems, scanned = [], 0
    for base in roots:
        for path in sorted(p for e in SOURCE_EXTENSIONS for p in base.rglob(f'*{e}')) if base.exists() else []:
            if any(part in {'.build', 'DerivedData', '.swiftpm'} for part in path.parts): continue
            scanned += 1
            code = strip_comments(path.read_text(errors='replace'))
            for kind, pattern in SOURCE_PATTERNS.items():
                for match in re.finditer(pattern, code):
                    line = code.count('\n', 0, match.start()) + 1
                    problems.append(f'{path}:{line}: {kind}: {match.group(0)}')
    return problems, scanned


# W26 (MAC09): user-assigned GLOBAL shortcuts use the public hot-key registration API, which delivers only the chords that were registered and neither taps
# nor monitors other input. It is allowed in exactly one file (the app target's composition root), so no package target and no test can register a real
# system-wide hot key (that would take a chord from the account holder's other apps). Event taps and global monitors stay banned everywhere, in that
# file too: the rules above still apply to it.
HOTKEY_PATTERN = r'\bRegisterEventHotKey\b|\bUnregisterEventHotKey\b|\bInstallEventHandler\b|\bCopySymbolicHotKeys\b|\bGetApplicationEventTarget\b'
HOTKEY_ALLOWED = {ROOT / 'App/Sources/NativeMusicApp.swift'}


def strip_strings(text: str) -> str:
    return re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)


def scan_hotkeys(roots, allowed=HOTKEY_ALLOWED):
    problems, scanned = [], 0
    for base in roots:
        for path in sorted(base.rglob('*.swift')) if base.exists() else []:
            if any(part in {'.build', 'DerivedData', '.swiftpm'} for part in path.parts): continue
            scanned += 1
            if path in allowed: continue
            code = strip_strings(strip_comments(path.read_text(errors='replace')))
            for match in re.finditer(HOTKEY_PATTERN, code):
                line = code.count('\n', 0, match.start()) + 1
                problems.append(f'{path}:{line}: hot-key registration outside the app target: {match.group(0)}')
    return problems, scanned


def scan_entitlements(paths):
    problems = []
    for path in paths:
        try: data = plistlib.loads(path.read_bytes())
        except Exception as error: problems.append(f'{path}: unreadable entitlements ({error})'); continue
        for key, value in data.items():
            if ENTITLEMENT_PRIVATE.search(key): problems.append(f'{path}: forbidden entitlement {key}')
            if key == MACH_LOOKUP:
                for name in value if isinstance(value, list) else [value]:
                    if MACH_FORBIDDEN.search(str(name)): problems.append(f'{path}: Mach lookup exception for {name}')
    return problems


def scan_signed_entitlements(app: Path):
    """The entitlements the BUILT app is actually signed with (a Debug build adds Xcode's own test-harness exceptions; none may touch media or HID)."""
    if not app.exists(): return [], False
    raw = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', str(app)], capture_output=True).stdout
    start = raw.find(b'<?xml')
    if start < 0: return [], True
    holder = Path(tempfile.mkdtemp(prefix='ytmuse-system-media-signed-')) / 'signed.entitlements'
    try:
        holder.write_bytes(raw[start:]); return scan_entitlements([holder]), True
    finally:
        holder.unlink(missing_ok=True); holder.parent.rmdir()


def scan_linkage(paths):
    problems = []
    for path in paths:
        if not path.exists(): continue
        for number, line in enumerate(path.read_text(errors='replace').splitlines(), 1):
            if re.search(r'linkedFramework|OTHER_LDFLAGS|-framework|FRAMEWORK|lib\w+\.tbd|\.framework', line) and LINKAGE.search(line):
                problems.append(f'{path}:{number}: forbidden linkage: {line.strip()[:120]}')
    return problems


def scan_binary(path: Path):
    problems = []
    symbols = subprocess.run(['nm', '-u', str(path)], capture_output=True, text=True).stdout
    for match in BINARY_SYMBOLS.finditer(symbols): problems.append(f'{path}: undefined symbol {match.group(0)}')
    strings = subprocess.run(['strings', '-a', str(path)], capture_output=True, text=True).stdout
    for name in sorted({m.group(0) for m in BINARY_STRINGS.finditer(strings)}): problems.append(f'{path}: carries the string {name}')
    if path.suffix != '.o':
        libraries = subprocess.run(['otool', '-L', str(path)], capture_output=True, text=True).stdout
        for match in BINARY_LIBRARIES.finditer(libraries): problems.append(f'{path}: links {match.group(0)}')
    return problems


def default_binaries():
    """The app's own modules as SwiftPM links them (one relinked object per module), and a built app if there is one."""
    found = sorted((ROOT / 'Packages/NativeMusic/.build/debug').glob('*.o'))
    app = ROOT / '.build/xcode/Build/Products/Debug/YTMuse.app/Contents'
    for folder in (app / 'MacOS', app / 'Frameworks'):
        if folder.exists(): found += [p for p in sorted(folder.iterdir()) if p.is_file() and (p.suffix in {'', '.dylib'})]
    return found


def run(roots, entitlements, linkage, binaries):
    problems, scanned = scan_sources(roots)
    hotkey_problems, hotkey_scanned = scan_hotkeys(roots + [ROOT / 'Packages/NativeMusic/Tests', ROOT / 'Tests'])
    problems += hotkey_problems; scanned += 0 if hotkey_scanned else 0
    problems += scan_entitlements(entitlements)
    problems += scan_linkage(linkage)
    for binary in binaries: problems += scan_binary(binary)
    signed, present = scan_signed_entitlements(ROOT / '.build/xcode/Build/Products/Debug/YTMuse.app')
    problems += signed
    print(f'signed entitlements of the built app: {"checked" if present else "no built app found (checked again after a UI build)"}')
    return problems, scanned


def self_test():
    with tempfile.TemporaryDirectory(prefix='ytmuse-system-media-selftest-') as tmp:
        tmp = Path(tmp)
        clean = tmp / 'clean'; clean.mkdir()
        (clean / 'Clean.swift').write_text('// no CGEventTapCreate here, only a sentence about it\nimport MediaPlayer\nlet c = MPRemoteCommandCenter.shared()\nlet u = "https://example.com/a" // IOHIDManager in a comment\n')
        problems, scanned = scan_sources([clean])
        assert scanned == 1 and not problems, f'clean tree flagged: {problems}'
        dirty = tmp / 'dirty'; dirty.mkdir()
        samples = {
            'event tap': 'let t = CGEventTapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap, 0, cb, nil)',
            'global event monitor': 'NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }',
            'media-key (system-defined) monitor': 'NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { $0 }',
            'IOHID access': 'let m = IOHIDManagerCreate(nil, 0)',
            'private MediaRemote': 'let f = MRMediaRemoteGetNowPlayingInfo',
            'dynamic loading': 'let h = dlopen("x", 0)',
            'private framework path': 'let p = "/System/Library/PrivateFrameworks/MediaRemote.framework"',
            'dynamic loading [split path]': 'let b = Bundle(path: base + "/Media" + "Remote.framework")?.load()',
            'dynamic selector': 'let s = NSSelectorFromString("addGlobalMonitorFor" + "EventsMatchingMask:handler:")',
            'dynamic selector [swift selector from pieces]': 'let t = Selector(("addGlobalMonitorFor" + "EventsMatchingMask:handler:"))',
            'dynamic loading [bundle by identifier]': 'let f = CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier("com.apple." + "Media" + "Remote" as CFString), "MRMediaRemoteGetNowPlayingInfo" as CFString)',
        }
        for index, (kind, code) in enumerate(samples.items()):
            (dirty / f'S{index}.swift').write_text(code + '\n')
        problems, _ = scan_sources([dirty])
        for index, kind in enumerate(samples):
            base_kind = kind.split(' [')[0]
            # Each probe must be flagged by ITS OWN file: two probes of one kind must not vouch for each other.
            assert any(f'S{index}.swift' in p and f': {base_kind}:' in p for p in problems), f'self-test: {kind} not flagged'
        good = tmp / 'good.entitlements'; good.write_bytes(plistlib.dumps({}))
        assert not scan_entitlements([good]), 'empty entitlements flagged'
        bad = tmp / 'bad.entitlements'
        bad.write_bytes(plistlib.dumps({'com.apple.private.tcc.allow': ['kTCCServiceListenEvent'], MACH_LOOKUP: ['com.apple.mediaremoted.xpc']}))
        found = scan_entitlements([bad]); assert len(found) == 2, f'entitlements: {found}'
        project = tmp / 'project.pbxproj'; project.write_text('OTHER_LDFLAGS = ("-framework", MediaRemote);\n')
        assert scan_linkage([project]), 'linkage not flagged'
        # Symbols: an object that really references an event tap and one that does not.
        source = tmp / 'tap.c'; source.write_text('extern void *CGEventTapCreate(int,int,int,unsigned long long,void*,void*);\nvoid f(void){ CGEventTapCreate(0,0,0,0,0,0); }\n')
        tapped, plain = tmp / 'tap.o', tmp / 'plain.o'
        subprocess.run(['clang', '-c', str(source), '-o', str(tapped)], check=True, capture_output=True)
        (tmp / 'plain.c').write_text('void g(void){}\n')
        subprocess.run(['clang', '-c', str(tmp / 'plain.c'), '-o', str(plain)], check=True, capture_output=True)
        assert scan_binary(tapped), 'binary with an event-tap symbol not flagged'
        # A global monitor is a selector NAME, not a symbol, and a MediaRemote path is a string, not a linkage: the strings layer must see both.
        (tmp / 'named.c').write_text('const char *a = "addGlobalMonitorForEventsMatchingMask:handler:";\nconst char *b = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote";\n')
        named = tmp / 'named.o'; subprocess.run(['clang', '-c', str(tmp / 'named.c'), '-o', str(named)], check=True, capture_output=True)
        found = scan_binary(named)
        assert any('addGlobalMonitorForEvents' in p for p in found) and any('MediaRemote' in p for p in found), f'strings layer: {found}'
        # A Swift call to NSEvent.addGlobalMonitorForEvents appears in an object file only as the objc_msgSend stub symbol, which carries the selector.
        (tmp / 'stub.c').write_text('extern void stub(void) __asm__("_objc_msgSend$addGlobalMonitorForEventsMatchingMask:handler:");\nvoid f(void){ stub(); }\n')
        stub = tmp / 'stub.o'; subprocess.run(['clang', '-c', str(tmp / 'stub.c'), '-o', str(stub)], check=True, capture_output=True)
        assert any('addGlobalMonitorForEvents' in p for p in scan_binary(stub)), 'the objc_msgSend stub symbol is not flagged'
        # Literal selectors that are not banned names stay legal, and a Selector built from pieces is not.
        legal = tmp / 'legal'; legal.mkdir(); (legal / 'L.swift').write_text('let a = Selector(("showSettingsWindow:"))\nlet b = #selector(NSApplication.terminate(_:))\n')
        assert not scan_sources([legal])[0], 'a literal Selector was flagged'
        # Objective-C and C sources are scanned like Swift.
        objc = tmp / 'objc'; objc.mkdir(); (objc / 'Tap.m').write_text('[NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^(NSEvent *e){}];\n')
        assert scan_sources([objc])[0], 'an Objective-C global monitor is not flagged'
        assert not scan_binary(plain), 'clean binary flagged'
        # W26: the hot-key allowance is exactly one file, and it does not weaken the tap and monitor rules.
        hot = tmp / 'hot'; hot.mkdir()
        (hot / 'Registrar.swift').write_text('let s = RegisterEventHotKey(0, 0, id, GetApplicationEventTarget(), 0, &ref)\n')
        (hot / 'Mentions.swift').write_text('// RegisterEventHotKey in a comment\nlet text = "InstallEventHandler in a string"\n')
        found = scan_hotkeys([hot], allowed=set())
        assert found[0] and all('Registrar.swift' in p for p in found[0]) and len(found[0]) >= 2, f'hot-key registration outside the allowed file not flagged: {found}'
        assert not scan_hotkeys([hot], allowed={hot / 'Registrar.swift'})[0], 'the allowed file was flagged, or a comment/string was'
        (hot / 'Registrar.swift').write_text('let s = RegisterEventHotKey(0, 0, id, GetApplicationEventTarget(), 0, &ref)\nNSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }\nlet t = CGEventTapCreate(.cgSessionEventTap, .headInsertEventTap, .defaultTap, 0, cb, nil)\n')
        tapped = scan_sources([hot])[0]
        assert any('global event monitor' in p for p in tapped) and any('event tap' in p for p in tapped), 'a monitor or tap beside a hot key is no longer flagged'
        assert HOTKEY_ALLOWED == {ROOT / 'App/Sources/NativeMusicApp.swift'}, 'the hot-key allowance grew'
    print('PASS: system-media guard self-test (every forbidden kind flagged; clean tree, comments and clean binary pass)')


def main():
    if '--self-test' in sys.argv: self_test(); return 0
    extra = [Path(sys.argv[i + 1]) for i, a in enumerate(sys.argv) if a == '--binary']
    roots = [ROOT / 'Packages/NativeMusic/Sources', ROOT / 'App/Sources', ROOT / 'Extensions/Sources']
    entitlements = [p for p in ROOT.rglob('*.entitlements') if not any(part in {'.build', 'DerivedData'} for part in p.parts)]
    linkage = [ROOT / 'Packages/NativeMusic/Package.swift'] + list(ROOT.glob('App/*.xcodeproj/project.pbxproj')) + list(ROOT.glob('App/*.yml'))
    binaries = default_binaries() + extra
    problems, scanned = run(roots, entitlements, linkage, binaries)
    if scanned == 0: print('FAIL: no sources were scanned (a guard over nothing proves nothing)'); return 1
    if problems:
        print('FAIL: system-media guard'); [print('  ' + p) for p in problems]; return 1
    print(f'PASS: no global tap or private accessory protocol: {scanned} sources, {len(entitlements)} entitlement files, {len(linkage)} linkage files, {len(binaries)} binaries')
    return 0


if __name__ == '__main__':
    sys.exit(main())
