#!/usr/bin/env python3
"""W25 (MAC06, ARCH09, T25.4): what the widget extension can reach, from its sources and from the BUILT bundle.

It reports two layers separately, because a clean source says nothing about what linked and a clean bundle says nothing about what a later edit adds:
  source  WidgetShared and the extension's own sources import only the allowed frameworks, name no network, WebKit, Keychain, playback, timer or WidgetCenter
          API, return only the `.never` timeline policy, and name the real App Group container (`containerURL(forSecurityApplicationGroupIdentifier:)`) in
          exactly the extension's entry file and the app target, never in a package or a test. The group in both entitlement files is the one the code names.
  bundle  the widget extension product (Build/Products/<config>/NativeMusicWidget.appex; a worktree build does NOT embed it in the app) links none of the networking, WebKit, Security, AV or MediaPlayer frameworks, references no URLSession / SecItem /
          WKWebView / AVPlayer / NWConnection symbol, and carries no store, database, cookie or Keychain file. (Its entitlements are checked by check-intents.py.)
What this does NOT establish: that the system, running the installed widget, makes no request. That is observed on an installed widget (W41), never inferred.
`--self-test` proves each rule fails on a planted defect and passes the real sources.

Usage: check-widget.py [--appex PATH_TO_NativeMusicWidget.appex] [--source-only] [--self-test]
"""
import plistlib, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WIDGET_SHARED = ROOT / 'Packages/NativeMusic/Sources/WidgetShared'
EXTENSION_SOURCES = ROOT / 'Extensions/Sources/NativeMusicWidget'
APP_SOURCES = ROOT / 'App/Sources'
APPEX = 'Contents/PlugIns/NativeMusicWidget.appex'
ALLOWED_IMPORTS = {'Foundation', 'SwiftUI', 'WidgetKit', 'AppIntents', 'AppKit', 'CryptoKit', 'ImageIO', 'UniformTypeIdentifiers', 'DesignSystem', 'WidgetShared'}
FORBIDDEN_TOKENS = {
    'a network API': r'\bURLSession\b|\bURLRequest\b|\bNWConnection\b|\bNWPathMonitor\b|\bCFNetwork\b|\bNSURLConnection\b',
    'WebKit': r'\bWKWebView\b|\bWKWebsiteDataStore\b',
    'the Keychain': r'\bSecItem\w*|\bkSecClass\w*|\bKeychain\w*',
    'a player': r'\bAVPlayer\b|\bAVAudioEngine\b|\bMPNowPlayingInfoCenter\b|\bMPRemoteCommandCenter\b',
    'a timer or polling loop': r'\bTimer\.|\bTimer\(|\bDispatchSource\w*|\basyncAfter\b|\bTask\.sleep\b|\bTimelineView\b',
    'WidgetCenter (a widget never reloads itself; the app does)': r'\bWidgetCenter\b',
    'a scheduled timeline policy (only .never is allowed)': r'policy:\s*\.(after|atEnd)\b|\.atEnd\b|\.after\(',
    'the real Spotlight index': r'\bCSSearchableIndex\b|\bCoreSpotlight\b',
}
CONTAINER_CALL = r'containerURL\s*\(\s*forSecurityApplicationGroupIdentifier'
FORBIDDEN_FRAMEWORKS = {'WebKit', 'Security', 'Network', 'CFNetwork', 'AVFoundation', 'AVKit', 'MediaPlayer', 'NetworkExtension', 'SystemConfiguration', 'LocalAuthentication',
                        'AuthenticationServices', 'CoreSpotlight', 'WidgetKitSupport'}
FORBIDDEN_SYMBOLS = re.compile(r'URLSession|NSURLConnection|SecItem|WKWebView|AVPlayer|NWConnection|NWPathMonitor|CSSearchableIndex')
FORBIDDEN_FILES = re.compile(r'\.(db|sqlite|sqlite3|keychain-db|keychain|cookies|binarycookies)$|cookie', re.I)


def swift_files(*folders):
    return [p for folder in folders if folder.exists() for p in sorted(folder.rglob('*.swift'))]


def code_of(text):
    """Source without line comments and doc comments (a rule about CODE must not fire on prose)."""
    return '\n'.join(re.sub(r'//.*$', '', line) for line in text.splitlines())


def check_source(shared=WIDGET_SHARED, extension=EXTENSION_SOURCES, app=APP_SOURCES, entitlements=None):
    problems = []
    files = swift_files(shared, extension)
    if not files: return ['no widget sources found: the check would pass vacuously']
    for path in files:
        text = path.read_text(); code = code_of(text)
        for module in set(re.findall(r'^import (\w+)', text, re.M)):
            if module not in ALLOWED_IMPORTS: problems.append(f'{path.name} imports {module}: the widget side may import only {sorted(ALLOWED_IMPORTS)}')
        for name, pattern in FORBIDDEN_TOKENS.items():
            if re.search(pattern, code): problems.append(f'{path.name} names {name}')
        if re.search(CONTAINER_CALL, code) and path.parent != extension: problems.append(f'{path.name} names the real App Group container: only the extension entry file may')
    if 'policy: .never' not in '\n'.join(f.read_text() for f in files): problems.append('the timeline provider no longer returns the .never policy')
    entry = [f for f in files if f.parent == extension and re.search(CONTAINER_CALL, code_of(f.read_text()))]
    if not entry: problems.append('the extension does not read the App Group container at all')
    app_hits = [f.name for f in swift_files(app) if re.search(CONTAINER_CALL, code_of(f.read_text()))]
    if len(app_hits) > 1: problems.append(f'the app names the real App Group container in more than one file: {app_hits}')
    suffix = set(re.findall(r'appGroupSuffix\s*=\s*"([^"]+)"', (shared / 'WidgetIdentity.swift').read_text() if (shared / 'WidgetIdentity.swift').exists() else ''))
    template = {'$(TeamIdentifierPrefix)' + x for x in suffix}
    canonical = entitlements if entitlements is not None else [ROOT / 'App/NativeMusic.entitlements', ROOT / 'Extensions/NativeMusicWidget.entitlements']
    for path in canonical:
        try: groups = plistlib.loads(path.read_bytes()).get('com.apple.security.application-groups', [])
        except Exception as error: problems.append(f'{path.name} unreadable: {error}'); continue
        if set(groups) != template: problems.append(f'{path.name} names App Group(s) {groups} but the code needs {sorted(template)} (the Team ID prefix is a build variable, never a literal)')
        if re.search(r'[A-Z0-9]{10}\.' + re.escape(next(iter(suffix), '?')), path.read_text()): problems.append(f'{path.name} contains a literal Team ID')
    if entitlements is None:
        for path in [ROOT / 'App/NativeMusic-adhoc.entitlements', ROOT / 'Extensions/NativeMusicWidget-adhoc.entitlements']:
            ents = plistlib.loads(path.read_bytes())
            if 'com.apple.security.application-groups' in ents: problems.append(f'{path.name} names an App Group: an ad-hoc build must never touch the group')
        for path in [ROOT / 'App/Info.plist', ROOT / 'Extensions/NativeMusicWidget-Info.plist']:
            value = plistlib.loads(path.read_bytes()).get('YTMuseAppGroup')
            if value not in template: problems.append(f'{path.name} YTMuseAppGroup is {value!r}, not the build-variable form')
        script = (ROOT / 'scripts/embed-widget.sh').read_text()
        if 'YTMUSE_EMBED_WIDGET:-NO' not in script: problems.append('the embed phase no longer defaults to NO: a worktree build would embed the extension')
    return problems


def tool(args):
    result = subprocess.run(args, capture_output=True, text=True)
    return result.returncode, result.stdout


def check_bundle(appex: Path, run=tool):
    problems = []
    if not appex.exists(): return [f'no widget extension product at {appex.name}']
    binaries = [p for p in sorted((appex / 'Contents/MacOS').glob('*'))] if (appex / 'Contents/MacOS').exists() else []
    if not binaries: return ['the widget extension has no executable']
    for binary in binaries:
        status, text = run(['otool', '-L', str(binary)])
        if status != 0: problems.append(f'otool could not read {binary.name}'); continue
        linked = set(re.findall(r'/(\w+)\.framework/', text))
        for framework in sorted(linked & FORBIDDEN_FRAMEWORKS): problems.append(f'{binary.name} links {framework}.framework')
        status, symbols = run(['nm', '-u', str(binary)])
        if status != 0: problems.append(f'nm could not read {binary.name}'); continue
        hits = sorted({m.group(0) for line in symbols.splitlines() if (m := FORBIDDEN_SYMBOLS.search(line))})
        if hits: problems.append(f'{binary.name} references {", ".join(hits)}')
    for path in appex.rglob('*'):
        if path.is_file() and FORBIDDEN_FILES.search(path.name): problems.append(f'the extension carries {path.relative_to(appex)}')
    try: key = plistlib.loads((appex / 'Contents/Info.plist').read_bytes()).get('YTMuseAppGroup', '')
    except Exception as error: key = f'unreadable ({error})'
    if not str(key).endswith('local.native-music.development'): problems.append(f'the extension Info.plist does not name the group the code reads: {key!r}')
    return problems


def report(appex, source_only):
    problems = check_source()
    for p in problems: print('SOURCE FAIL:', p)
    if problems: return 1
    print('source:  PASS  widget sources import only the allowed frameworks and name no network, WebKit, Keychain, player, timer, WidgetCenter or real Spotlight API; '
          '.never timeline policy; the real App Group container is named only by the extension entry and one app file; the entitlement templates hold the Team ID prefix as a build variable, no literal team; ad-hoc entitlements hold no group; the embed phase defaults to NO')
    if source_only or appex is None: return 0
    bundle = check_bundle(appex)
    for p in bundle: print('BUNDLE FAIL:', p)
    if bundle: return 1
    print('bundle:  PASS  the built extension product links no networking, WebKit, Security, AV or MediaPlayer framework, references no URLSession / SecItem / WKWebView / AVPlayer symbol, '
          'and carries no database, cookie or Keychain file')
    print('process: NOT OBSERVED  what an installed widget does at run time (requests, wake-ups) is a live observation (W41)')
    return 0


def self_test():
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        shared = root / 'shared'; ext = root / 'ext'; app = root / 'app'
        for folder in (shared, ext, app): folder.mkdir()
        for f in WIDGET_SHARED.glob('*.swift'): (shared / f.name).write_text(f.read_text())
        for f in EXTENSION_SOURCES.glob('*.swift'): (ext / f.name).write_text(f.read_text())
        (app / 'SystemWidgetSupport.swift').write_text('let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: g)\n')
        ents = [ROOT / 'App/NativeMusic.entitlements', ROOT / 'Extensions/NativeMusicWidget.entitlements']
        assert check_source(shared, ext, app, ents) == [], f'the real sources pass: {check_source(shared, ext, app, ents)}'
        plants = {
            'an import of WebKit': ('import WebKit\n', 'imports WebKit'),
            'an import of Security': ('import Security\n', 'imports Security'),
            'an import of Playback': ('import Playback\n', 'imports Playback'),
            'URLSession': ('let s = URLSession.shared\n', 'a network API'),
            'a Keychain call': ('let q = SecItemCopyMatching\n', 'the Keychain'),
            'a Timer': ('let t = Timer.scheduledTimer\n', 'a timer or polling loop'),
            'a sleep loop': ('func poll() async { try? await Task.sleep(for: .seconds(1)) }\n', 'a timer or polling loop'),
            'WidgetCenter': ('let c = WidgetCenter.shared\n', 'WidgetCenter'),
            'an after policy': ('let p = Timeline(entries: [], policy: .after(Date()))\n', 'a scheduled timeline policy'),
            'the real Spotlight index': ('let i = CSSearchableIndex.default()\n', 'the real Spotlight index'),
            'the real container in the shared module': ('let u = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "x")\n', 'only the extension entry'),
        }
        for name, (line, expect) in plants.items():
            planted = shared / 'Planted.swift'; planted.write_text(line)
            found = check_source(shared, ext, app, ents)
            assert any(expect in p for p in found), f'{name} must be reported ({expect!r}); got {found}'
            planted.unlink()
        # A comment is not code: a rule about code must not fire on prose.
        (shared / 'Prose.swift').write_text('// URLSession and WidgetCenter are named here only in a comment\nimport Foundation\n')
        assert check_source(shared, ext, app, ents) == [], 'comments are not code'
        (shared / 'Prose.swift').unlink()
        twice = app / 'Second.swift'; twice.write_text('let u = containerURL(forSecurityApplicationGroupIdentifier: g)\n')
        assert any('more than one file' in p for p in check_source(shared, ext, app, ents)), 'two app files naming the container must be reported'
        twice.unlink()
        for f in ext.glob('*.swift'): f.unlink()
        assert any('does not read the App Group' in p for p in check_source(shared, ext, app, ents)), 'an extension that never reads the container must be reported'
        assert check_source(root / 'nothing', root / 'nothing2', app, ents), 'no sources at all must fail, not pass'
        # Bundle layer with a stubbed otool / nm: the standalone extension product.
        appex = root / 'NativeMusicWidget.appex'; (appex / 'Contents/MacOS').mkdir(parents=True); (appex / 'Contents/MacOS/NativeMusicWidget').write_bytes(b'')
        (appex / 'Contents/Info.plist').write_bytes(plistlib.dumps({'YTMuseAppGroup': 'local.native-music.development'}))
        def runner(frameworks=('Foundation', 'SwiftUI', 'WidgetKit'), symbols=('_swift_retain',)):
            def run(args, *_):
                if args[0] == 'otool': return 0, '\n'.join(f'\t/System/Library/Frameworks/{f}.framework/Versions/A/{f} (compatibility version 1.0.0)' for f in frameworks)
                return 0, '\n'.join(f'                 U {s}' for s in symbols)
            return run
        assert check_bundle(appex, runner()) == [], 'a clean bundle passes'
        for fw in ('WebKit', 'Security', 'Network', 'AVFoundation', 'MediaPlayer'):
            assert any(fw in p for p in check_bundle(appex, runner(frameworks=('Foundation', fw)))), f'{fw} linkage must be reported'
        for sym in ('$s10Foundation10URLSessionC6sharedACvgZ', '_SecItemAdd', '_OBJC_CLASS_$_WKWebView', '_OBJC_CLASS_$_AVPlayer'):
            assert check_bundle(appex, runner(symbols=(sym,))), f'{sym} must be reported'
        (appex / 'Contents/Resources').mkdir(); (appex / 'Contents/Resources/session.cookies').write_text('x')
        assert any('carries' in p for p in check_bundle(appex, runner())), 'a cookie file in the extension must be reported'
        (appex / 'Contents/Resources/session.cookies').unlink()
        (appex / 'Contents/Info.plist').write_bytes(plistlib.dumps({'YTMuseAppGroup': 'group.something.else'}))
        assert any('does not name the group' in p for p in check_bundle(appex, runner())), 'an extension that reads another group must be reported'
        assert any('no widget extension' in p for p in check_bundle(root / 'Empty.appex', runner())), 'a missing extension must be reported'
        assert any('could not read' in p for p in check_bundle(appex, lambda args, *_: (1, ''))), 'a tool failure must be reported, not read as clean'
        # Source layer: the signing-related rules.
        wrong = root / 'wrong.entitlements'; wrong.write_bytes(plistlib.dumps({'com.apple.security.application-groups': ['group.local.native-music.development']}))
        assert any('build variable' in p for p in check_source(shared, ext, app, [wrong])), 'an unprefixed group in an entitlement file must be reported'
        literal = root / 'literal.entitlements'; literal.write_bytes(plistlib.dumps({'com.apple.security.application-groups': ['$(TeamIdentifierPrefix)local.native-music.development']})); 
        assert not any('build variable' in p or 'literal' in p for p in check_source(shared, ext, app, [literal])), 'the placeholder form passes'
        withteam = root / 'withteam.entitlements'; withteam.write_text(literal.read_text().replace('<plist', '<!-- ABCDE12345.local.native-music.development --><plist', 1))
        assert any('literal Team ID' in p for p in check_source(shared, ext, app, [withteam])), 'a literal team in an entitlement file must be reported'
    print('self-test: PASS  each rule fails on its planted defect, comments are not code, and the real sources and a clean bundle pass')


if __name__ == '__main__':
    if '--self-test' in sys.argv: self_test(); sys.exit(0)
    appex = Path(sys.argv[sys.argv.index('--appex') + 1]) if '--appex' in sys.argv else None
    sys.exit(report(appex, '--source-only' in sys.argv))
