#!/usr/bin/env python3
"""No test writes a persistent preferences domain (operator rule, 2026-11-01).

Background: a W28 test switched on Foundation's double-length pseudolanguage with `UserDefaults.standard.set(...)`. In a test process that is the
shared PERSISTENT domain of the Swift Testing runner (~/Library/Preferences/swiftpm-testing-helper.plist), so every lane's tests then ran with doubled
strings. A scratch probe binary named `t` had also created ~/Library/Preferences/t.plist. Tests use the in-memory registration domain
(`UserDefaults.standard.register(defaults:)`), a volatile domain, or a per-test suite with a unique name that they remove afterwards.

  check-test-preferences.py                 scan test sources and scripts for persistent writes (exit 1 on any)
  check-test-preferences.py --self-test     plant each forbidden pattern and require the scan to catch it
  check-test-preferences.py snapshot FILE   record the key set of every domain under ~/Library/Preferences (names only, never values)
  check-test-preferences.py compare FILE    diff against a snapshot; fails when a watched key appeared anywhere, or a test-runner / probe-binary domain gained a key (window-frame keys excepted) or a new file
"""
import json, os, plistlib, re, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PREFERENCES = Path(os.environ.get('YTMUSE_PREFERENCES_DIR') or Path.home() / 'Library/Preferences')   # the override exists for the self-test
# Swift: writes to the standard domain or to a persistent domain by name. A per-test suite (`UserDefaults(suiteName:)`) is the allowed form, and
# `removePersistentDomain` is allowed only on a suite the same file created with a unique name.
SWIFT_FORBIDDEN = [
    (r'UserDefaults\.standard\.(set|setValue|setValuesForKeys|removeObject|removePersistentDomain|setPersistentDomain)\(', 'writes the standard (persistent) domain'),
    (r'UserDefaults\(\)\s*\.(set|setValue|setValuesForKeys|removeObject|setPersistentDomain)\(', 'UserDefaults() IS the standard domain'),
    (r'UserDefaults\(\s*suiteName:\s*"(swiftpm|xctest|swift-test|com\.apple\.dt)[^"]*"\s*\)\s*!?\??\s*\.(set|setValue|removeObject|setValuesForKeys)\(', 'writes the test runner\'s own domain'),
    (r'\.setPersistentDomain\(', 'setPersistentDomain'),
    (r'CFPreferencesSet(AppValue|Value|Multiple)\(', 'CFPreferencesSet*'),
    (r'CFPreferencesAppSynchronize\(\s*kCFPreferencesCurrentApplication', 'synchronises the current application domain'),
]
SHELL_FORBIDDEN = [
    (r'\bdefaults\s+(write|delete|import|rename)\b', '`defaults write`'),
    (r'plutil\s+-(insert|replace|remove|create)\b[^\n]*Library/Preferences', 'plutil edit of a preferences file'),
    (r'PlistBuddy[^\n]*Library/Preferences', 'PlistBuddy edit of a preferences file'),
]
def strip_comments(text, lang):
    out = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if (lang == 'swift' and stripped.startswith('//')) or (lang != 'swift' and stripped.startswith('#')): out.append(''); continue
        out.append(line)
    return '\n'.join(out)
def scan_swift(text):
    code = strip_comments(text, 'swift')
    problems = []
    for pattern, why in SWIFT_FORBIDDEN:
        for match in re.finditer(pattern, code): problems.append((code[:match.start()].count('\n') + 1, why))
    # removePersistentDomain on anything: allowed only when the file builds a uniquely named suite itself.
    for match in re.finditer(r'\.removePersistentDomain\(', code):
        if 'UserDefaults(suiteName:' not in code: problems.append((code[:match.start()].count('\n') + 1, 'removePersistentDomain on a domain the file did not create'))
    return problems
def scan_shell(text, lang):
    code = strip_comments(text, lang)
    return [(code[:m.start()].count('\n') + 1, why) for pattern, why in SHELL_FORBIDDEN for m in re.finditer(pattern, code)]
def scan():
    problems = []
    for path in sorted((ROOT / 'Packages/NativeMusic/Tests').rglob('*.swift')) + sorted((ROOT / 'Tests').rglob('*.swift')):
        if path.name == 'TestPreferencesGuardTests.swift': continue   # holds the patterns as data
        for line, why in scan_swift(path.read_text()): problems.append(f'{path.relative_to(ROOT)}:{line}: {why}')
    for path in sorted((ROOT / 'scripts').rglob('*')):
        if path.suffix not in ('.sh', '.py') or path.name == 'check-test-preferences.py': continue
        if path.name in ('IntentDonationGuardTests.swift',): continue
        for line, why in scan_shell(path.read_text(), 'py' if path.suffix == '.py' else 'sh'): problems.append(f'{path.relative_to(ROOT)}:{line}: {why}')
    return problems
def self_test():
    cases = [('swift', 'UserDefaults.standard.set(true, forKey: "NSDoubleLocalizedStrings")'), ('swift', 'UserDefaults.standard.removeObject(forKey: k)'),
             ('swift', 'defaults.setPersistentDomain([:], forName: "x")'), ('swift', 'CFPreferencesSetAppValue("k" as CFString, 1 as CFNumber, kCFPreferencesCurrentApplication)'),
             ('swift', 'UserDefaults.standard.removePersistentDomain(forName: "t")'), ('swift', 'x.removePersistentDomain(forName: name)'),
             ('swift', 'UserDefaults().set(true, forKey: "NSDoubleLocalizedStrings")'), ('swift', 'UserDefaults.standard.setValue(true, forKey: "k")'),
             ('swift', 'UserDefaults(suiteName: "swiftpm-testing-helper")!.set(true, forKey: "NSDoubleLocalizedStrings")'),
             ('sh', 'defaults write -g NSDoubleLocalizedStrings -bool YES'), ('sh', 'defaults delete swiftpm-testing-helper'),
             ('sh', 'plutil -replace k -bool YES ~/Library/Preferences/x.plist')]
    for lang, text in cases:
        found = scan_swift(text) if lang == 'swift' else scan_shell(text, 'sh')
        assert found, f'not caught: {text}'
    allowed = ['UserDefaults.standard.register(defaults: ["NSDoubleLocalizedStrings": true])', 'let s = UserDefaults(suiteName: "w-" + UUID().uuidString)!; defer { s.removePersistentDomain(forName: n) }',
               '// UserDefaults.standard.set(1, forKey: "x") in a comment', 'let v = UserDefaults.standard.string(forKey: "x")']
    for text in allowed: assert not scan_swift(text), f'wrongly flagged: {text}'
    # The snapshot comparison, against a throwaway preferences folder.
    global PREFERENCES
    saved = PREFERENCES
    with tempfile.TemporaryDirectory(prefix='ytmuse-prefs-selftest-') as folder:
        PREFERENCES = Path(folder)
        # Fail safe (operator rule, 2026-11-01): this self-test creates and DELETES plist files in the folder it works in, so it stops before any file operation
        # unless that folder is the throwaway one it just made, under the system temporary directory, and is not the account holder's preferences folder.
        real = (Path.home() / 'Library/Preferences').resolve()
        if not (PREFERENCES.resolve() != real and PREFERENCES.resolve().is_relative_to(Path(tempfile.gettempdir()).resolve()) and PREFERENCES.name.startswith('ytmuse-prefs-selftest-')):
            raise SystemExit(f'REFUSING: the self-test folder {PREFERENCES} is not a throwaway folder')
        def put(name, data): (PREFERENCES / name).write_bytes(plistlib.dumps(data))
        put('swiftpm-testing-helper.plist', {'NSWindow Frame A': 'x'}); put('com.example.app.plist', {'k': 1})
        snap = Path(tempfile.mkdtemp()) / 'snapshot.json'; snapshot(str(snap))
        def attempt(change, expect_fail, label):
            before = {p: p.read_bytes() for p in PREFERENCES.glob('*.plist')}
            change(); import io, contextlib
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()): status = compare(str(snap))
            assert (status != 0) == expect_fail, f'compare gave {status} for: {label}'
            for p in list(PREFERENCES.glob('*.plist')): p.unlink()
            for p, data in before.items(): p.write_bytes(data)
        attempt(lambda: put('swiftpm-testing-helper.plist', {'NSWindow Frame A': 'x', 'NSDoubleLocalizedStrings': True}), True, 'the 2026-11-01 incident: the pseudolanguage key in the runner domain')
        attempt(lambda: put('swiftpm-testing-helper.plist', {'NSWindow Frame A': 'x', 'SomeOtherKey': 1}), True, 'any new key in the runner domain')
        attempt(lambda: put('t.plist', {}), True, 'a probe binary leaves a domain behind')
        attempt(lambda: put('com.example.app.plist', {'k': 1, 'AppleLanguages': ['de']}), True, 'a watched key in any domain')
        attempt(lambda: put('swiftpm-testing-helper.plist', {'NSWindow Frame A': 'x', 'NSWindow Frame B': 'y'}), False, 'a window-frame autosave key from some test window')
        attempt(lambda: put('ytmuse-w30-X.plist', {'a': 1}), False, 'a parallel lane\'s per-test suite file')
        attempt(lambda: put('com.example.app.plist', {'k': 2, 'other': 3}), False, 'an unrelated application writing its own preferences')
    PREFERENCES = saved
    print(f'self-test: {len(cases)} forbidden writes caught, {len(allowed)} allowed forms pass, 7 snapshot comparisons judged correctly')
def keys_of(path):
    try: data = plistlib.loads(path.read_bytes())
    except Exception: return None
    return sorted(data) if isinstance(data, dict) else None
def snapshot(target):
    state = {p.name: keys_of(p) for p in sorted(PREFERENCES.glob('*.plist'))}
    Path(target).write_text(json.dumps(state, sort_keys=True)); print(f'snapshot: {len(state)} domains (key names only)')
WATCH = re.compile(r'NSDoubleLocalizedStrings|AppleLanguages|AppleLocale|AppleTextDirection|NSForceRightToLeft|AppleReduce|AppleEnhancedAccessibility|AppleDisplayScale')
# The domains a test run writes through `UserDefaults.standard` (the Swift Testing helper and XCTest runner) and the names a stray probe binary leaves behind.
RUNNER = re.compile(r'^(swiftpm|swift-test|swift-testing|xctest|com\.apple\.dt\.xctest|xcodebuild|t|[a-z]{1,2})(-[^.]*)?\.plist$')
# Window-frame autosave keys some test's window writes; reported, and not attributable to a preference a test chose to set.
FRAME = re.compile(r'^(NSWindow Frame|NSSplitView Subview Frames|NSToolbar Configuration|NSNavPanel|NSOSPLastRootDirectory)')
def compare(source):
    before = json.loads(Path(source).read_text())
    after = {p.name: keys_of(p) for p in sorted(PREFERENCES.glob('*.plist'))}
    bad, info = [], []
    for name in sorted(set(before) | set(after)):
        b, a = set(before.get(name) or []), set(after.get(name) or [])
        if name not in before:
            info.append(f'new domain file {name} (another process; a per-test suite of a parallel lane leaves such a file)')
            if RUNNER.match(name): bad.append(f'new preferences file {name} in a test-runner or probe-binary domain')
        elif name not in after: info.append(f'removed domain {name}')
        for key in sorted(a - b):
            info.append(f'{name}: + {key}')
            if WATCH.search(key): bad.append(f'{name} gained {key}')
            elif RUNNER.match(name) and not FRAME.match(key): bad.append(f'test-runner domain {name} gained {key}')
        for key in sorted(b - a): info.append(f'{name}: - {key}')
    for line in info: print('  changed:', line)
    if bad: print('FAIL:', *bad, sep='\n  ', file=sys.stderr); return 1
    print(f'preferences: no watched key gained, no test-runner domain gained a key a test could have set ({len(info)} unrelated change(s) listed above, made by other processes)' if info else 'preferences unchanged: no domain gained or lost a key')
    return 0
def main():
    args = sys.argv[1:]
    if args[:1] == ['--self-test']: self_test(); return 0
    if args[:1] == ['snapshot']: snapshot(args[1]); return 0
    if args[:1] == ['compare']: return compare(args[1])
    problems = scan()
    for p in problems: print('FAIL:', p, file=sys.stderr)
    if problems: print(f'{len(problems)} persistent preferences write(s) in tests or scripts', file=sys.stderr); return 1
    print('test-preferences guard: no test or script writes a persistent preferences domain'); return 0
if __name__ == '__main__': sys.exit(main())
