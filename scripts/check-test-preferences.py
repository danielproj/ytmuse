#!/usr/bin/env python3
"""No test writes a persistent preferences domain (operator rule, 2026-11-01).

Background: a W28 test switched on Foundation's double-length pseudolanguage with `UserDefaults.standard.set(...)`. In a test process that is the
shared PERSISTENT domain of the Swift Testing runner (~/Library/Preferences/swiftpm-testing-helper.plist), so every lane's tests then ran with doubled
strings. A scratch probe binary named `t` had also created ~/Library/Preferences/t.plist. Tests use the in-memory registration domain
(`UserDefaults.standard.register(defaults:)`), a volatile domain, TestSupport's `InMemoryDefaults`, or TestSupport's `ScratchDefaults` (a file inside the test's own
scratch folder). TH3: a per-test suite NAME is no longer allowed either: a named suite writes `~/Library/Preferences/<name>.plist` (cfprefsd rewrites it after
a test deletes it), and 17,833 such files had to be deleted on 2026-11-01. `UserDefaults(suiteName:)` appears only in Tests/TestSupport.
TH5: the scan also catches an alias of the standard domain (`let d = UserDefaults.standard; d.set(...)`, a parameter defaulting to it, `UserDefaults()`), a `typealias` around the type,
a call chained over several lines, `defaults -currentHost|-host H write`, the list form (`subprocess.run(["defaults", "write", ...])`, also in Swift), a Swift `Process` over
/usr/bin/defaults, and scripts anywhere in the repository (not only scripts/), with a shebang when they have no suffix. A line that holds the words as data (`"defaults write" not in ui`)
is exempt, and so are the lines named in LINE_ALLOWED. Residual risk: a verb or tool name assembled at run time (a variable, an f-string) leaves no text to match.

  check-test-preferences.py                 scan test sources and scripts for persistent writes (exit 1 on any)
  check-test-preferences.py --self-test     plant each forbidden pattern and require the scan to catch it
  check-test-preferences.py count           count the per-test suite files (names only) under ~/Library/Preferences, per name pattern (TH3 proof: the count must not grow over a quiet window)
  check-test-preferences.py snapshot FILE   record the key set of every domain under ~/Library/Preferences (names only, never values)
  check-test-preferences.py compare FILE    diff against a snapshot; fails when a watched key appeared anywhere, or a test-runner / probe-binary domain gained a key (window-frame keys excepted) or a new file
"""
import hashlib, json, os, plistlib, re, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PREFERENCES = Path(os.environ.get('YTMUSE_PREFERENCES_DIR') or Path.home() / 'Library/Preferences')   # the override exists for the self-test
# Swift: writes to the standard domain or to a persistent domain by name. A per-test suite (`UserDefaults(suiteName:)`) is the allowed form, and
# `removePersistentDomain` is allowed only on a suite the same file created with a unique name.
# TH5: `{UD}` stands for every spelling of the UserDefaults type in the file (the type itself, and any typealias around it); `\s*` around the dots accepts the call
# chained over several lines (`UserDefaults.standard\n    .set(...)`).
WRITES = r'(set|setValue|setValuesForKeys|removeObject|removePersistentDomain|setPersistentDomain)'
SWIFT_FORBIDDEN = [
    (r'{UD}\s*\.\s*standard\s*\.\s*' + WRITES + r'\s*\(', 'writes the standard (persistent) domain'),
    (r'{UD}\s*\(\s*\)\s*\.\s*(set|setValue|setValuesForKeys|removeObject|setPersistentDomain)\s*\(', 'UserDefaults() IS the standard domain'),
    (r'{UD}\s*\(\s*suiteName:\s*"(swiftpm|xctest|swift-test|com\.apple\.dt)[^"]*"\s*\)\s*!?\??\s*\.(set|setValue|removeObject|setValuesForKeys)\(', 'writes the test runner\'s own domain'),
    (r'\.setPersistentDomain\(', 'setPersistentDomain'),
    (r'CFPreferencesSet(AppValue|Value|Multiple)\(', 'CFPreferencesSet*'),
    (r'CFPreferencesAppSynchronize\(\s*kCFPreferencesCurrentApplication', 'synchronises the current application domain'),
    (r'["\']/usr/bin/defaults["\']', 'runs the `defaults` tool'),
]
# TH5: a name bound to the standard domain, then written through. `let d = UserDefaults.standard`, `var d: UserDefaults = .standard`, a parameter defaulting to it,
# `let d = UserDefaults()` (the same domain). The alias is then held to the same write rules as the type itself.
STANDARD_ALIAS = [
    r'\b(?:let|var)\s+(\w+)\s*(?::[^=\n]+)?=\s*\(?\s*{UD}\s*\.\s*standard\b',
    r'\b(?:let|var)\s+(\w+)\s*:\s*{UD}\??\s*=\s*\.standard\b',
    r'\b(\w+)\s*:\s*{UD}\??\s*=\s*(?:{UD}\s*)?\.\s*standard\b',
    r'\b(?:let|var)\s+(\w+)\s*(?::[^=\n]+)?=\s*{UD}\s*\(\s*\)',
]
# TH5: a typealias around the type hides every rule above from the files that use the alias.
TYPEALIAS = re.compile(r'\btypealias\s+(\w+)\s*=\s*(?:NS)?UserDefaults\b')
# `defaults -currentHost write` and `defaults -host H write` put options between the tool and its verb.
DEFAULTS_VERB = r'\bdefaults\s+(?:(?:-currentHost|-host\s+\S+)\s+)*(write|delete|import|rename)\b'
# The list form (`subprocess.run(["defaults", "write", ...])`, `["/usr/bin/defaults", "-currentHost", "write"]`): the tool and the verb are separate string literals.
DEFAULTS_LIST = r'["\'](?:[^"\'\n]*/)?defaults["\']\s*,\s*(?:["\']-(?:currentHost|host)["\']\s*,\s*(?:["\'][^"\'\n]*["\']\s*,\s*)?)*["\'](write|delete|import|rename)["\']'
SHELL_FORBIDDEN = [
    (DEFAULTS_VERB, '`defaults write`'),
    (DEFAULTS_LIST, '`defaults write` as an argument list'),
    (r'plutil\s+-(insert|replace|remove|create)\b[^\n]*Library/Preferences', 'plutil edit of a preferences file'),
    (r'PlistBuddy[^\n]*Library/Preferences', 'PlistBuddy edit of a preferences file'),
]
# TH3: a `UserDefaults(suiteName:)` / `.init(suiteName:)` / `super.init(suiteName:)` in a test creates a preferences domain of its own. The only files that may
# open one are TestSupport's (which name a path inside a scratch folder, or never write at all).
SUITE_OPENING = r'({UD}\s*\(\s*suiteName\s*:|{UD}\s*\.\s*init\s*\(\s*suiteName\s*:|\binit\s*\(\s*suiteName\s*:|\bNSUserDefaults\b)'
def with_names(pattern, names):
    return pattern.replace('{UD}', '(?:' + '|'.join(sorted(map(re.escape, names))) + ')')
SUITE_ALLOWED = ('Packages/NativeMusic/Tests/TestSupport/',)
def strip_comments(text, lang):
    out = []
    for line in text.splitlines():
        stripped = line.lstrip()
        if (lang == 'swift' and stripped.startswith('//')) or (lang != 'swift' and stripped.startswith('#')): out.append(''); continue
        out.append(line)
    return '\n'.join(out)
def type_names(code, extra=()):
    """Every spelling of UserDefaults in this file: the type, typealiases declared in it, and those found elsewhere (`extra`)."""
    return {'UserDefaults', *extra, *TYPEALIAS.findall(code)}
def scan_swift(text, relative_path=None, extra_names=()):
    code = strip_comments(text, 'swift')
    problems = []
    names = type_names(code, extra_names)
    inside_support = bool(relative_path and relative_path.startswith(SUITE_ALLOWED))
    if not inside_support:
        for match in re.finditer(with_names(SUITE_OPENING, names), code): problems.append((code[:match.start()].count('\n') + 1, 'opens a defaults suite by name or path outside TestSupport (use InMemoryDefaults or ScratchDefaults)'))
        for match in TYPEALIAS.finditer(code): problems.append((code[:match.start()].count('\n') + 1, 'a typealias around UserDefaults hides it from these rules (use InMemoryDefaults or ScratchDefaults)'))
    for pattern, why in SWIFT_FORBIDDEN + SHELL_FORBIDDEN:
        for match in re.finditer(with_names(pattern, names), code): problems.append((code[:match.start()].count('\n') + 1, why))
    aliases = {name for pattern in STANDARD_ALIAS for match in re.finditer(with_names(pattern, names), code) for name in [match.group(1)]}
    for alias in sorted(aliases):
        for match in re.finditer(r'\b' + re.escape(alias) + r'\s*\.\s*' + WRITES + r'\s*\(', code):
            problems.append((code[:match.start()].count('\n') + 1, f'writes the standard (persistent) domain through the alias `{alias}`'))
    # removePersistentDomain on anything: allowed only when the file builds a uniquely named suite itself.
    for match in re.finditer(r'\.removePersistentDomain\(', code):
        if 'UserDefaults(suiteName:' not in code or not inside_support: problems.append((code[:match.start()].count('\n') + 1, 'removePersistentDomain on a domain the file did not create'))
    return sorted(set(problems))
def scan_shell(text, lang):
    code = strip_comments(text, lang)
    return [(code[:m.start()].count('\n') + 1, why) for pattern, why in SHELL_FORBIDDEN for m in re.finditer(pattern, code)]
# TH5: scripts are swept wherever they live, not only under scripts/. A script-like file is one with a script suffix, or no suffix and a `#!` line. Directories that hold
# build output, third-party code or version-control data are not ours.
SCRIPT_SUFFIXES = {'.sh', '.zsh', '.bash', '.command', '.py', '.rb', '.pl', '.js', '.applescript', '.scpt'}
SKIPPED_DIRECTORIES = {'.git', '.build', 'DerivedData', '.swiftpm', 'node_modules', 'Pods', 'build', '__pycache__', '.venv'}
# Files that hold the forbidden words as DATA or deliberately perform the action under a reviewed fence. Each entry names the file and the reason; a new entry is a review
# decision. (The guard itself, which holds every pattern as data, is excluded by name.)
SCRIPT_ALLOWED = {}   # whole files: none (every exemption below is a single line)
# A single line that holds the words as DATA: (file, the line as written, stripped) -> why.
LINE_ALLOWED = {
    # Keyed by the SHA-256 of the stripped line, so this table does not itself spell the words it exempts (the donation guard sweeps this file too).
    ('Packages/NativeMusic/Tests/PlaybackTests/Intents/IntentDonationGuardTests.swift', '764fc1ac22deb39b15db98cd39901f00b8c203449001e61751eb8979cae90b1a'):
        'a rule of the donation guard, held with its planted text as data; nothing runs it',
}
# `"defaults write" not in ui`: a check that a file does NOT contain the words. It is the opposite of the write, and eight isolation proofs say exactly that.
ABSENCE_ASSERTION = re.compile(r'["\']defaults\s+(write|delete|import|rename)["\']\s+not\s+in\b')
def exempt(relative, text, line):
    lines = text.splitlines()
    source = lines[line - 1] if 0 < line <= len(lines) else ''
    return (relative, hashlib.sha256(source.strip().encode()).hexdigest()) in LINE_ALLOWED or bool(ABSENCE_ASSERTION.search(source))
def is_script(path):
    if path.suffix in SCRIPT_SUFFIXES: return True
    if path.suffix: return False
    try:
        with path.open('rb') as handle: return handle.read(2) == b'#!'
    except OSError: return False
def script_files(root=None):
    root = root or ROOT
    found = []
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = sorted(d for d in subdirectories if d not in SKIPPED_DIRECTORIES)
        for name in sorted(names):
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file() or path.name == 'check-test-preferences.py' or not is_script(path): continue
            found.append(path)
    return found
def scan_scripts(root=None):
    root = root or ROOT
    problems = []
    for path in script_files(root):
        relative = str(path.relative_to(root))
        if relative in SCRIPT_ALLOWED: continue
        try: text = path.read_text()
        except (UnicodeDecodeError, OSError) as error: problems.append(f'{relative}:0: a script this guard cannot read ({error.__class__.__name__})'); continue
        for line, why in scan_shell(text, 'sh' if path.suffix in ('.sh', '.zsh', '.bash', '.command', '') else 'py'):
            if not exempt(relative, text, line): problems.append(f'{relative}:{line}: {why}')
    return problems
def scan():
    problems = []
    swift_files = sorted((ROOT / 'Packages/NativeMusic/Tests').rglob('*.swift')) + sorted((ROOT / 'Tests').rglob('*.swift'))
    # TH5: a typealias around UserDefaults in one test file is a spelling of the type in every other.
    aliases = {name for path in swift_files if path.name != 'TestPreferencesGuardTests.swift' for name in TYPEALIAS.findall(strip_comments(path.read_text(), 'swift'))}
    for path in swift_files:
        if path.name == 'TestPreferencesGuardTests.swift': continue   # holds the patterns as data
        text = path.read_text()
        for line, why in scan_swift(text, str(path.relative_to(ROOT)), aliases):
            if not exempt(str(path.relative_to(ROOT)), text, line): problems.append(f'{path.relative_to(ROOT)}:{line}: {why}')
    return problems + scan_scripts(ROOT)
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
    allowed = ['UserDefaults.standard.register(defaults: ["NSDoubleLocalizedStrings": true])', 'let s = InMemoryDefaults(); s.set(1, forKey: "k")',
               'let scratch = ScratchDefaults(); let s = scratch.defaults; s.set(1, forKey: "k")',
               '// UserDefaults.standard.set(1, forKey: "x") in a comment', 'let v = UserDefaults.standard.string(forKey: "x")']
    for text in allowed: assert not scan_swift(text, 'Packages/NativeMusic/Tests/SettingsTests/X.swift'), f'wrongly flagged: {text}'
    # TH3: a suite opened by name or path is refused everywhere in the tests except TestSupport, whatever the name (the 17,833 files of 2026-11-01).
    suites = ['let s = UserDefaults(suiteName: "ytmuse-settings-test-" + UUID().uuidString)!', 'let s = UserDefaults (suiteName: path)', 'let s = try #require(UserDefaults(suiteName: "local.native-music.test-" + UUID().uuidString))',
              'let s = UserDefaults.init(suiteName: name)', 'init() { super.init(suiteName: "x")! }', 'let s = UserDefaults(suiteName:\n  "ytmuse-w22-" + id)', 'let d = NSUserDefaults(suiteName: "x")',
              'let s = UserDefaults(suiteName: "w-" + UUID().uuidString)!; defer { s.removePersistentDomain(forName: n) }']
    for text in suites:
        assert scan_swift(text, 'Packages/NativeMusic/Tests/PlaybackTests/X.swift'), f'suite opening not caught: {text}'
        assert scan_swift(text, 'Tests/UITests/X.swift'), f'suite opening not caught in the app UI tests: {text}'
        assert not [p for p in scan_swift(text, 'Packages/NativeMusic/Tests/TestSupport/ScratchDefaults.swift') if 'suite' in p[1]], f'TestSupport wrongly refused: {text}'
    assert scan_swift('s.removePersistentDomain(forName: n)', 'Packages/NativeMusic/Tests/X/X.swift'), 'removePersistentDomain outside TestSupport must be caught'
    # TH5 (TH3 critic L2): the forms the older rules missed. Every one has a plant (must be caught) and a clean control (must pass).
    test_path = 'Packages/NativeMusic/Tests/PlaybackTests/X.swift'
    swift_plants = {
        'an alias of the standard domain': 'let prefs = UserDefaults.standard\nprefs.set(true, forKey: "NSDoubleLocalizedStrings")',
        'an annotated alias': 'var prefs: UserDefaults = .standard\nprefs.removeObject(forKey: "k")',
        'a parameter defaulting to the standard domain': 'func apply(to defaults: UserDefaults = .standard) { defaults.set(1, forKey: "k") }',
        'an alias of UserDefaults()': 'let d = UserDefaults()\nd.setValue(1, forKey: "k")',
        'a call chained over several lines': 'UserDefaults.standard\n    .set(true, forKey: "k")',
        'a typealias around the type, then a write': 'typealias Prefs = UserDefaults\nPrefs.standard.set(1, forKey: "k")',
        'a typealias used to open a suite': 'typealias Prefs = UserDefaults\nlet s = Prefs(suiteName: "x")',
        'a typealias declaration alone': 'typealias Prefs = UserDefaults',
        'a typealias around NSUserDefaults': 'typealias Prefs = NSUserDefaults',
        'Process running defaults': 'process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")',
        'a Swift argument list': 'let args = ["defaults", "-currentHost", "write", "-g", "k", "-bool", "YES"]',
    }
    for label, text in swift_plants.items(): assert scan_swift(text, test_path), f'not caught ({label}): {text}'
    swift_controls = {
        'an alias that only reads': 'let prefs = UserDefaults.standard\nlet v = prefs.string(forKey: "k")',
        'an alias that registers': 'let prefs = UserDefaults.standard\nprefs.register(defaults: ["k": 1])',
        'an in-memory store named like an alias': 'let prefs = InMemoryDefaults()\nprefs.set(true, forKey: "k")',
        'a scratch store': 'let scratch = ScratchDefaults(); scratch.defaults.set(1, forKey: "k")',
        'an unrelated typealias': 'typealias Handler = (Int) -> Void',
    }
    for label, text in swift_controls.items(): assert not scan_swift(text, test_path), f'wrongly flagged ({label}): {text}'
    assert scan_swift('Prefs.standard.set(1, forKey: "k")', test_path, extra_names={'Prefs'}), 'a typealias declared in another file is a spelling of the type'
    assert not scan_swift('Prefs.standard.set(1, forKey: "k")', test_path), 'control: without the alias name the same text is not a UserDefaults write'
    shell_plants = {
        '`defaults -currentHost write`': 'defaults -currentHost write -g NSDoubleLocalizedStrings -bool YES',
        '`defaults -host h write`': 'defaults -host somehost write com.example k 1',
        'both options': 'defaults -currentHost -host h delete com.example',
        'a path to the tool': '/usr/bin/defaults write com.example k 1',
        'the Python list form': 'subprocess.run(["defaults", "write", "-g", "k", "-bool", "YES"], check=True)',
        'the list form with a path': "subprocess.run(['/usr/bin/defaults', 'write', 'com.example', 'k', '1'])",
        'the list form with -currentHost': 'subprocess.check_call(["defaults", "-currentHost", "write", "x", "y"])',
        'the list form with -host and a name': 'subprocess.run(["defaults", "-host", "h", "delete", "x"])',
    }
    for label, text in shell_plants.items(): assert scan_shell(text, 'py'), f'not caught ({label}): {text}'
    shell_controls = {
        'defaults read': 'defaults read com.example k',
        'the list form of a read': 'subprocess.run(["defaults", "read", "com.example", "k"])',
        'the list form of a read with -currentHost': 'subprocess.run(["defaults", "-currentHost", "read", "x"])',
        'an absence assertion': 'check("UI runner never writes", "defaults write" not in ui)',
        'an unrelated tool with write in its list': 'subprocess.run(["plutil", "write", "x"])',
        'a comment': '# defaults write -g k 1 is what not to do',
    }
    for label, text in shell_controls.items():
        found = [item for item in scan_shell(text, 'py') if not exempt('x.py', text, item[0])]
        assert not found, f'wrongly flagged ({label}): {text}'
    # Scripts outside scripts/: a throwaway tree with a plant in a directory the old scan never looked at, a shebang file without a suffix, and clean controls.
    with tempfile.TemporaryDirectory(prefix='ytmuse-prefs-selftest-') as folder:
        tree = Path(folder)
        for relative, text in {'Tools/helper.py': 'import subprocess\nsubprocess.run(["defaults", "write", "-g", "k", "1"])\n', 'artifacts/run': '#!/bin/sh\ndefaults -currentHost write -g k 1\n',
                               'Tests/ui/prepare.sh': 'defaults write com.example k 1\n', 'Tools/clean.py': 'import subprocess\nsubprocess.run(["defaults", "read", "-g", "k"])\n',
                               '.build/ignored.py': 'defaults write -g k 1\n', 'Tools/data.txt': 'defaults write -g k 1\n'}.items():
            target = tree / relative; target.parent.mkdir(parents=True, exist_ok=True); target.write_text(text)
        flagged = sorted(item.split(':')[0] for item in scan_scripts(tree))
        assert flagged == ['Tests/ui/prepare.sh', 'Tools/helper.py', 'artifacts/run'], f'scripts outside scripts/: {flagged}'
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
    print(f'self-test: {len(cases)} forbidden writes caught, {len(allowed)} allowed forms pass, {len(suites)} suite openings refused outside TestSupport (and allowed inside), '
          f'{len(swift_plants)} Swift plants caught ({len(swift_controls)} controls pass), {len(shell_plants)} shell plants caught ({len(shell_controls)} controls pass), scripts outside scripts/ swept, 7 snapshot comparisons judged correctly')
# TH3 proof: the names (never the contents) of the per-test suite files a test run can leave under ~/Library/Preferences.
SUITE_FILE_PATTERNS = ['ytmuse-settings-test-', 'ytmuse-diag-test-', 'ytmuse-erase-test-', 'ytmuse-w22-', 'ytmuse-w30-', 'ytmuse-w28-', 'ytmuse-w39-', 'ytmuse-w10-', 'ytmuse-th2-', 'ytmuse.tests.', 'local.native-music.test-']
def count():
    names = sorted(p.name for p in PREFERENCES.glob('*.plist'))
    total = 0
    for prefix in SUITE_FILE_PATTERNS:
        n = sum(1 for name in names if name.startswith(prefix)); total += n; print(f'{prefix}* {n}')
    print(f'total {total}'); return 0
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
    if args[:1] == ['count']: return count()
    if args[:1] == ['snapshot']: snapshot(args[1]); return 0
    if args[:1] == ['compare']: return compare(args[1])
    problems = scan()
    for p in problems: print('FAIL:', p, file=sys.stderr)
    if problems: print(f'{len(problems)} persistent preferences write(s) in tests or scripts', file=sys.stderr); return 1
    print('test-preferences guard: no test or script writes a persistent preferences domain'); return 0
if __name__ == '__main__': sys.exit(main())
