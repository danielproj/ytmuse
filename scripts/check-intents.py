#!/usr/bin/env python3
"""W24 (MAC03, MAC04, ARCH09, T24.4): what the App Intents layer declares in source, and what the BUILT app actually carries.

It reports three states separately, because they are three different claims and none implies the next:
  compile    the app built and its bundle carries generated App Intents metadata for exactly the intents, entities, queries and schemas the sources
             declare (read from Contents/Resources/Metadata.appintents/extract.actionsdata, which the SDK's own metadata processor wrote);
  shortcuts  the bundle declares the App Shortcuts and their phrases (extract.actionsdata `autoShortcuts`, en.lproj/AppShortcuts.strings). That the
             Shortcuts app LISTS them on a Mac is not observed here and is never inferred from this;
  siri       NOT OBSERVED. Whether Siri recognises a phrase, in any language, is a live observation (W41) and cannot be produced by a build.

Also fails closed on anything that would put playback, credentials or a store behind an intent: intents sources that import playback, account,
persistence or WebKit modules, and the bundle's embedding. W25 narrowed "no extension, no App Group" to exactly this, decided by whether the bundle is signed with a TEAM:
  * ad hoc or unsigned (no Team ID: every worktree, test and CI build): NO extension and NO App Group of any kind. Such a build never touches the group.
  * signed with a team (the operator's Release build): exactly ONE extension (Contents/PlugIns/NativeMusicWidget.appex, extension point com.apple.widgetkit-extension),
    signed by the same team as the app, and exactly ONE App Group, `<TeamID>.local.native-music.development`, the same in the app's and the extension's signed
    entitlements; the extension may hold only the sandbox and that group (no Keychain group, no network client or server, no file access, no exception).
Anything else fails. The widget button intent (WidgetTransportIntent, in WidgetShared) is expected in the built metadata as non-discoverable and as an audio-starting
system intent, which is what makes the system run it in the app process. The signed branch cannot be observed without a signing identity: it is proved on planted
bundles here and observed on the operator's real signed build with `--app`.
`--self-test` proves each check fails on a planted defect and passes the good case, so a green result cannot be vacuous.

Usage: check-intents.py [--app PATH_TO_YTMuse.app] [--source-only] [--self-test]
"""
import json, plistlib, re, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INTENTS = ROOT / 'Packages/NativeMusic/Sources/SystemIntegration/Intents'
WIDGET_SHARED = ROOT / 'Packages/NativeMusic/Sources/WidgetShared'
SHORTCUTS = ROOT / 'App/Sources/NativeMusicShortcuts.swift'
CATALOG = ROOT / 'Resources/AppShortcuts.xcstrings'
FORBIDDEN_IMPORTS = re.compile(r'^import (Playback|AccountSession|Persistence|AVFoundation|WebKit|Security|Downloads|StreamResolver|YouTubeMusicAdapter)\b', re.M)


def declared(intents_dir: Path = INTENTS):
    text = '\n'.join(p.read_text() for p in sorted(intents_dir.glob('*.swift')))
    actions = set(re.findall(r'public struct (\w+): AppIntent\b', text))
    entities = set(re.findall(r'public struct (\w+): (?:AppEntity|TransientAppEntity)\b', text))
    queries = set(re.findall(r'public struct (\w+): EntityStringQuery\b', text))
    schemas = set(re.findall(r'schema: \.((?:audio|system)\.\w+)\)', text))
    return actions, entities, queries, schemas


def widget_actions(widget_dir: Path = WIDGET_SHARED):
    """The intents WidgetShared declares for the widget's buttons (W25): they are in the built metadata but are not part of the W24 inventory."""
    text = '\n'.join(p.read_text() for p in sorted(widget_dir.glob('*.swift')))
    return set(re.findall(r'public struct (\w+): AudioPlaybackIntent\b', text))


def phrases(shortcuts: Path = SHORTCUTS):
    text = shortcuts.read_text()
    found = []
    for group in re.findall(r'phrases: \[([^\]]*)\]', text):
        found += [p.replace('\\(.applicationName)', '${applicationName}') for p in re.findall(r'"([^"]+)"', group)]
    return found, len(re.findall(r'AppShortcut\(intent:', text))


def check_source(intents_dir=INTENTS, shortcuts=SHORTCUTS, catalog=CATALOG):
    problems = []
    actions, entities, queries, schemas = declared(intents_dir)
    if len(actions) < 16: problems.append(f'only {len(actions)} intents declared in source')
    if len(entities) < 6 or len(queries) < 5: problems.append(f'entities/queries incomplete: {len(entities)}/{len(queries)}')
    for path in intents_dir.glob('*.swift'):
        match = FORBIDDEN_IMPORTS.search(path.read_text())
        if match: problems.append(f'{path.name} imports {match.group(1)}: an intent must not reach playback, accounts, stores or the web')
    found, count = phrases(shortcuts)
    if not found or not 1 <= count <= 10: problems.append(f'shortcut count {count} outside 1...10')
    if any(p.count('${applicationName}') != 1 for p in found): problems.append('a phrase does not name the app exactly once')
    strings = json.loads(catalog.read_text()).get('strings', {})
    if set(strings) != set(found): problems.append(f'String Catalog and provider phrases differ: {sorted(set(strings) ^ set(found))}')
    return problems


def codesign(args, app):
    result = subprocess.run(['codesign', *args, str(app)], capture_output=True)
    # `-dv` / `-dvv` print their report on stderr; the entitlements print is on stdout.
    return result.returncode, (result.stderr if args and args[0] in ('-dv', '-dvv') else result.stdout)


GROUP_SUFFIX = 'local.native-music.development'
TEAM_GROUP = re.compile(r'^[A-Z0-9]{10}\.' + re.escape(GROUP_SUFFIX) + r'$')
WIDGET_APPEX = 'Contents/PlugIns/NativeMusicWidget.appex'
WIDGET_POINT = 'com.apple.widgetkit-extension'


def entitlements_of(path: Path, run, label: str):
    """(entitlements dict or None, problems). An unsigned or unreadable signature FAILS: an empty print proves nothing."""
    status, _ = run(['-dv'], path)
    if status != 0: return None, [f'{label} carries no readable code signature, so its entitlements cannot be checked']
    status, text = run(['-d', '--entitlements', ':-'], path)
    if status != 0: return None, [f'codesign could not print the entitlements of {label}']
    if not text.strip(): return {}, []
    try: return plistlib.loads(text), []
    except Exception as error: return None, [f'the signed entitlements of {label} are unreadable: {error}']


def team_of(path: Path, run):
    """The Team ID the bundle is signed with, or None for ad hoc / unsigned."""
    status, text = run(['-dvv'], path)
    if status != 0: return None
    found = re.search(r'^TeamIdentifier=(.+?)\s*$', text.decode() if isinstance(text, bytes) else text, re.M)
    return found.group(1) if found and found.group(1) != 'not set' else None


def check_embedding(app: Path, run=codesign):
    """Decided by the signature: a bundle with no Team ID embeds no extension and holds no App Group; a bundle signed with a team has exactly the widget and exactly the
    team-prefixed group in both signatures."""
    problems = []
    found = sorted(app.rglob('*.appex')) if app.exists() else []
    for folder in ('Contents/PlugIns', 'Contents/Extensions'):
        found += [p for p in (app / folder).glob('*') if p not in found]
    widget = app / WIDGET_APPEX
    others = [p for p in found if p != widget]
    if others: problems.append(f'an app extension other than the widget is embedded ({others[0].relative_to(app)}): intents run in the app process')
    ents, more = entitlements_of(app, run, 'the bundle'); problems += more
    team = team_of(app, run)
    if team is None:
        # Ad hoc or unsigned: nothing embedded, nothing shared.
        if widget.exists(): problems.append('an ad-hoc or unsigned build embeds the widget extension: it can have no Team-ID-prefixed App Group, so no build without a team embeds it')
        if ents is not None and 'com.apple.security.application-groups' in ents: problems.append('an ad-hoc or unsigned build claims an App Group: it must never touch the group')
    else:
        group = f'{team}.{GROUP_SUFFIX}'
        if not widget.exists(): problems.append(f'a signed build does not embed the widget extension ({WIDGET_APPEX})')
        else:
            try: point = plistlib.loads((widget / 'Contents/Info.plist').read_bytes()).get('NSExtension', {}).get('NSExtensionPointIdentifier')
            except Exception as error: point = f'unreadable ({error})'
            if point != WIDGET_POINT: problems.append(f'the embedded extension is not a widget extension (extension point {point!r})')
            ext_ents, more = entitlements_of(widget, run, 'the widget extension'); problems += more
            if ext_ents is not None and ext_ents != {'com.apple.security.app-sandbox': True, 'com.apple.security.application-groups': [group]}:
                problems.append(f'the widget extension holds entitlements beyond the sandbox and the one team-prefixed App Group: {sorted(ext_ents)}')
            if team_of(widget, run) != team: problems.append('the widget extension is not signed by the same team as the app')
        if ents is not None:
            groups = ents.get('com.apple.security.application-groups')
            if groups != [group]: problems.append(f'the app must claim exactly the team-prefixed App Group and no other: {groups!r}')
            for key in ents:
                if key != 'com.apple.security.application-groups': problems.append(f'the app holds {key}')
            if groups is not None and not all(TEAM_GROUP.match(g) for g in groups): problems.append('the App Group does not carry a Team ID prefix: macOS would prompt for access')
    return problems


def check_bundle(app: Path, expected=None, run=codesign):
    problems, facts = [], {}
    meta = app / 'Contents/Resources/Metadata.appintents/extract.actionsdata'
    if not meta.exists(): return [f'no generated App Intents metadata in the bundle: {meta}'], facts
    data = json.loads(meta.read_text())
    actions, entities, queries, schemas = expected or declared()
    built_actions, built_entities, built_queries = set(data.get('actions', {})), set(data.get('entities', {})), set(data.get('queries', {}))
    buttons = widget_actions()
    if built_actions != actions | buttons: problems.append(f'intents differ (built vs source): {sorted(built_actions ^ (actions | buttons))}')
    for name in buttons & built_actions:
        item = data['actions'][name]
        if item.get('isDiscoverable') is not False: problems.append(f'{name} must not be discoverable (Shortcuts and Siri never offer a widget button)')
        if 'com.apple.link.systemProtocol.AudioStarting' not in item.get('systemProtocols', []):
            problems.append(f'{name} is not an audio-starting system intent: the system would not run it in the app process')
    if built_entities != entities: problems.append(f'entities differ: {sorted(built_entities ^ entities)}')
    if built_queries != queries: problems.append(f'queries differ: {sorted(built_queries ^ queries)}')
    built_schemas = {s['publicIdentifier'] for section in ('actions', 'entities') for item in data.get(section, {}).values() for s in item.get('assistantDefinedSchemas', [])}
    wanted = {s for s in schemas if s in ('audio.playAudio', 'audio.addToLibrary', 'audio.updateAudioAffinity', 'audio.song', 'audio.album', 'audio.artist', 'audio.playlist', 'audio.algorithmicRadioStation', 'audio.warmupAudioQueueResult', 'system.searchInApp')}
    if not wanted <= built_schemas: problems.append(f'audio schemas missing from the build: {sorted(wanted - built_schemas)}')
    shortcuts = data.get('autoShortcuts', [])
    source_phrases, source_count = phrases()
    built_phrases = {t['key'] for s in shortcuts for t in s.get('phraseTemplates', [])}
    if len(shortcuts) != source_count: problems.append(f'{len(shortcuts)} shortcuts built, {source_count} declared')
    if built_phrases != set(source_phrases): problems.append(f'built phrases differ from the String Catalog: {sorted(built_phrases ^ set(source_phrases))}')
    strings_file = app / 'Contents/Resources/en.lproj/AppShortcuts.strings'
    if not strings_file.exists(): problems.append('en.lproj/AppShortcuts.strings is not in the bundle')
    else:
        raw = strings_file.read_bytes()
        # The build writes the strings table as UTF-16 with an XML declaration that says UTF-8; read the text, not the declaration.
        if raw[:2] in (b'\xff\xfe', b'\xfe\xff'): raw = raw.decode('utf-16').replace('encoding="UTF-8"', 'encoding="utf-8"').encode('utf-8')
        try: table = plistlib.loads(raw)
        except Exception as error: table = {}; problems.append(f'AppShortcuts.strings unreadable: {error}')
        if set(table) != set(source_phrases): problems.append('AppShortcuts.strings does not hold exactly the declared phrases')
    problems += check_embedding(app, run)
    facts = dict(intents=len(built_actions & actions), entities=len(built_entities), queries=len(built_queries), shortcuts=len(shortcuts), phrases=len(built_phrases), schemas=sorted(built_schemas))
    return problems, facts


def report(app: Path | None, source_only: bool):
    problems = check_source()
    for p in problems: print('SOURCE FAIL:', p)
    if problems: return 1
    print('source:    PASS  intents, entities, queries, phrases and the String Catalog agree; no playback, account, store or web import in any intent')
    if source_only or app is None: return 0
    bundle_problems, facts = check_bundle(app)
    for p in bundle_problems: print('BUNDLE FAIL:', p)
    if bundle_problems: return 1
    print(f"compile:   PASS  built bundle carries metadata for {facts['intents']} intents, {facts['entities']} entities, {facts['queries']} queries; "
          f"schemas {', '.join(facts['schemas'])}; no extension and no App Group (ad hoc), or the one widget and the one team-prefixed group (signed)")
    print(f"shortcuts: DECLARED  {facts['shortcuts']} App Shortcuts with {facts['phrases']} phrases are in the bundle; the Shortcuts app listing them is NOT observed")
    print('siri:      NOT OBSERVED  phrase recognition in any language is a live observation (W41)')
    return 0


def self_test():
    import copy, tempfile
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        app = root / 'YTMuse.app'; (app / 'Contents/Resources/Metadata.appintents').mkdir(parents=True); (app / 'Contents/Resources/en.lproj').mkdir(parents=True)
        actions, entities, queries, schemas = declared()
        found, count = phrases()
        buttons = widget_actions()
        assert buttons, 'WidgetShared declares at least one widget button intent'
        data = {'actions': {a: {'assistantDefinedSchemas': []} for a in actions}, 'entities': {e: {'assistantDefinedSchemas': []} for e in entities}, 'queries': {q: {} for q in queries},
                'autoShortcuts': [{'phraseTemplates': [{'key': p} for p in found[i::count]]} for i in range(count)]}
        for b in buttons: data['actions'][b] = {'assistantDefinedSchemas': [], 'isDiscoverable': False, 'systemProtocols': ['com.apple.link.systemProtocol.AudioStarting']}
        data['actions']['PlayAudioIntent']['assistantDefinedSchemas'] = [{'publicIdentifier': s} for s in ('audio.playAudio', 'audio.addToLibrary', 'audio.updateAudioAffinity', 'system.searchInApp')]
        data['entities']['SongEntity']['assistantDefinedSchemas'] = [{'publicIdentifier': s} for s in ('audio.song', 'audio.album', 'audio.artist', 'audio.playlist', 'audio.algorithmicRadioStation', 'audio.warmupAudioQueueResult')]
        def write(d, strings=None):
            (app / 'Contents/Resources/Metadata.appintents/extract.actionsdata').write_text(json.dumps(d))
            (app / 'Contents/Resources/en.lproj/AppShortcuts.strings').write_bytes(plistlib.dumps(strings if strings is not None else {p: p for p in found}))
        TEAM = 'ABCDE12345'; GROUP = f'{TEAM}.{GROUP_SUFFIX}'
        EXT = {'com.apple.security.app-sandbox': True, 'com.apple.security.application-groups': [GROUP]}
        GOOD_APP = {'com.apple.security.application-groups': [GROUP]}
        # The runner answers per path: entitlements, and the team the bundle (and the extension) is signed with. team None = ad hoc.
        def signed(app_ents, ext_ents=EXT, team=TEAM, ext_team='same'):
            def run(args, path):
                is_ext = str(path).endswith('.appex')
                if args == ['-dv']: return 0, b''
                if args == ['-dvv']:
                    t = (team if ext_team == 'same' else ext_team) if is_ext else team
                    return 0, (f'TeamIdentifier={t}\n' if t else 'TeamIdentifier=not set\n').encode()
                ents = ext_ents if is_ext else app_ents
                return 0, plistlib.dumps(ents) if ents is not None else b''
            return run
        def plant_widget(point=WIDGET_POINT, name='NativeMusicWidget.appex', folder='Contents/PlugIns'):
            appex = app / folder / name; (appex / 'Contents').mkdir(parents=True, exist_ok=True)
            (appex / 'Contents/Info.plist').write_bytes(plistlib.dumps({'NSExtension': {'NSExtensionPointIdentifier': point}}))
            return appex
        def remove(path): shutil.rmtree(path, ignore_errors=True)
        def reported(label, problems, text):
            assert any(text in p for p in problems), f'{label} must be reported ({text!r}); got {problems}'
        write(data)
        # Metadata layer: the good case is an AD-HOC bundle with no extension.
        good, _ = check_bundle(app, run=signed({}, team=None))
        assert good == [], f'the good ad-hoc case must pass: {good}'
        cases = {}
        missing = copy.deepcopy(data); del missing['actions']['SeekIntent']; cases['a missing intent'] = (missing, None)
        extra = copy.deepcopy(data); extra['entities']['StrayEntity'] = {}; cases['an unexpected entity'] = (extra, None)
        stray = copy.deepcopy(data); stray['actions']['StrayIntent'] = {}; cases['an unexpected intent'] = (stray, None)
        noschema = copy.deepcopy(data); noschema['actions']['PlayAudioIntent']['assistantDefinedSchemas'] = []; cases['a dropped schema'] = (noschema, None)
        fewer = copy.deepcopy(data); fewer['autoShortcuts'] = fewer['autoShortcuts'][:-1]; cases['a missing shortcut'] = (fewer, None)
        visible = copy.deepcopy(data); visible['actions'][sorted(buttons)[0]]['isDiscoverable'] = True; cases['a discoverable widget button'] = (visible, None)
        inapp = copy.deepcopy(data); inapp['actions'][sorted(buttons)[0]]['systemProtocols'] = []; cases['a widget button the system would run in the extension'] = (inapp, None)
        nobutton = copy.deepcopy(data); del nobutton['actions'][sorted(buttons)[0]]; cases['a missing widget button'] = (nobutton, None)
        cases['phrases missing from the strings file'] = (data, {found[0]: found[0]})
        for name, (d, strings) in cases.items():
            write(d, strings)
            problems, _ = check_bundle(app, run=signed({}, team=None))
            assert problems, f'{name} must be reported'
        write(data)
        # Embedding, AD HOC / unsigned: nothing embedded, nothing shared.
        assert check_embedding(app, signed({}, team=None)) == [], 'an ad-hoc bundle with no extension and no group passes'
        reported('an unsigned bundle', check_embedding(app, lambda args, _p: (1, b'')), 'no readable code signature')
        reported('a failed entitlements print', check_embedding(app, lambda args, _p: (0, b'') if args in (['-dv'], ['-dvv']) else (1, b'')), 'could not print')
        reported('an App Group on an ad-hoc bundle', check_embedding(app, signed({'com.apple.security.application-groups': ['group.local.native-music.development']}, team=None)), 'must never touch the group')
        reported('a team-prefixed group on an ad-hoc bundle', check_embedding(app, signed(GOOD_APP, team=None)), 'must never touch the group')
        plant_widget()
        reported('the widget embedded in an ad-hoc bundle', check_embedding(app, signed({}, team=None)), 'no build without a team embeds it')
        remove(app / WIDGET_APPEX)
        # Embedding, SIGNED with a team: exactly the widget and exactly the team-prefixed group.
        reported('a signed build without the widget', check_embedding(app, signed(GOOD_APP)), 'does not embed the widget')
        plant_widget()
        assert check_embedding(app, signed(GOOD_APP)) == [], 'the widget and its one team-prefixed group pass'
        reported('an unprefixed group on a signed build', check_embedding(app, signed({'com.apple.security.application-groups': ['group.local.native-music.development']})), 'exactly the team-prefixed')
        reported('another team prefix on the app', check_embedding(app, signed({'com.apple.security.application-groups': [f'ZZZZZ99999.{GROUP_SUFFIX}']})), 'exactly the team-prefixed')
        reported('two groups on the app', check_embedding(app, signed({'com.apple.security.application-groups': [GROUP, 'group.other']})), 'exactly the team-prefixed')
        reported('no group on a signed build', check_embedding(app, signed({})), 'exactly the team-prefixed')
        reported('a Keychain access group on the app', check_embedding(app, signed(GOOD_APP | {'keychain-access-groups': ['x']})), 'keychain-access-groups')
        reported('an extension signed by another team', check_embedding(app, signed(GOOD_APP, ext_team='OTHERTEAM2')), 'same team')
        reported('an ad-hoc extension inside a signed app', check_embedding(app, signed(GOOD_APP, ext_team=None)), 'same team')
        for label, ents in {'a network client': EXT | {'com.apple.security.network.client': True},
                            'a network server': EXT | {'com.apple.security.network.server': True},
                            'a Keychain access group': EXT | {'keychain-access-groups': ['x']},
                            'file access': EXT | {'com.apple.security.files.user-selected.read-write': True},
                            'a temporary exception': EXT | {'com.apple.security.temporary-exception.mach-lookup.global-name': ['x']},
                            'a second group': {**EXT, 'com.apple.security.application-groups': [GROUP, 'group.other']},
                            'an unprefixed group': {**EXT, 'com.apple.security.application-groups': ['group.local.native-music.development']},
                            'no sandbox': {'com.apple.security.application-groups': [GROUP]}}.items():
            reported(f'a widget extension with {label}', check_embedding(app, signed(GOOD_APP, ents)), 'beyond the sandbox')
        reported('an unreadable extension signature', check_embedding(app, lambda args, p: (1, b'') if str(p).endswith('.appex') else signed(GOOD_APP)(args, p)), 'widget extension carries no readable')
        for folder in ('Contents/PlugIns', 'Contents/Extensions', 'Contents/Resources/deep'):
            other = plant_widget(name='Intent.appex', folder=folder)
            reported(f'a second extension in {folder}', check_embedding(app, signed(GOOD_APP)), 'other than the widget')
            remove(other)
        remove(app / 'Contents/Extensions'); remove(app / 'Contents/Resources/deep')
        plant_widget(point='com.apple.intents-service')
        reported('a widget bundle with another extension point', check_embedding(app, signed(GOOD_APP)), 'not a widget extension')
        # Source layer: a planted import and a catalog mismatch.
        bad = root / 'Intents'; bad.mkdir()
        for f in INTENTS.glob('*.swift'): (bad / f.name).write_text(f.read_text())
        assert check_source(bad) == [], 'the real sources pass'
        (bad / 'Planted.swift').write_text('import Playback\npublic struct PlantedIntent: AppIntent {}\n')
        assert any('imports Playback' in p for p in check_source(bad)), 'a playback import must be reported'
        wrong = root / 'catalog.xcstrings'; wrong.write_text(json.dumps({'strings': {'Only ${applicationName}': {}}}))
        assert any('differ' in p for p in check_source(INTENTS, SHORTCUTS, wrong)), 'a catalog mismatch must be reported'
    print('self-test: PASS  each check fails on its planted defect and the good case passes')


if __name__ == '__main__':
    if '--self-test' in sys.argv: self_test(); sys.exit(0)
    app = None
    if '--app' in sys.argv: app = Path(sys.argv[sys.argv.index('--app') + 1])
    sys.exit(report(app, '--source-only' in sys.argv))
