#!/usr/bin/env python3
"""W25 (F2): proves scripts/sign-bundle.sh signs INNER TO OUTER with one identity and fills the Team ID prefix in without ever writing it down, using a STUB codesign.

No real identity, certificate, Keychain item or team is involved: a stub `codesign` on PATH records what it is asked and answers `-dvv` with a made-up team. The made-up
team below exists only inside this process's temporary directory. What this proves is the script's ORDER and CONTENT; that a real Apple Development identity signs a real
bundle that macOS then lets use the group is a signing observation (G08 / W41), made by the operator's Release build with `check-intents.py --app`.

Usage: check-signing.py --self-test
"""
import os, plistlib, re, shutil, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FAKE_TEAM = 'TESTTEAM01'
STUB = r'''#!/bin/bash
# stub codesign: logs every call; answers -dvv from the environment; --verify succeeds unless STUB_VERIFY_FAIL is set
log="$STUB_LOG"; n=$(( $(cat "$log.count" 2>/dev/null || echo 0) + 1 )); echo $n > "$log.count"
echo "$n $*" >> "$log"
prev=""
for a in "$@"; do
  if [[ "$prev" == --entitlements ]]; then cp "$a" "$log.ents.$n"; fi
  prev="$a"
done
# a signing call that fails midway: STUB_FAIL_ON=<suffix of the target>; only real-identity signatures fail, so the restore's ad-hoc signature goes through
if [[ -n "${STUB_FAIL_ON:-}" && " $* " == *" --entitlements "* && " $* " != *" --sign - "* && "${@: -1}" == *"$STUB_FAIL_ON" ]]; then exit 1; fi
case " $* " in
  *" --verify "*) [[ -z "${STUB_VERIFY_FAIL:-}" ]]; exit $? ;;
  *" -dvv "*)
    target="${@: -1}"
    case "$target" in
      *probe.appex) team="${STUB_TEAM-}" ;;
      *.appex) team="${STUB_APPEX_TEAM-${STUB_TEAM-}}" ;;
      *) team="${STUB_APP_TEAM-${STUB_TEAM-}}" ;;
    esac
    echo "Authority=${STUB_AUTHORITY-Apple Development: Stub Person (ABCDE12345)}" >&2
    if [[ -n "$team" ]]; then echo "TeamIdentifier=$team" >&2; else echo "TeamIdentifier=not set" >&2; fi
    exit 0 ;;
esac
exit 0
'''

def make_app(root: Path, with_appex=True):
    app = root / 'YTMuse.app'
    (app / 'Contents').mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleName': 'YTMuse', 'YTMuseAppGroup': '$(TeamIdentifierPrefix)local.native-music.development'}))
    if with_appex:
        appex = app / 'Contents/PlugIns/NativeMusicWidget.appex'; (appex / 'Contents').mkdir(parents=True)
        (appex / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleName': 'NativeMusicWidget', 'YTMuseAppGroup': '$(TeamIdentifierPrefix)local.native-music.development'}))
    return app

def run_sign(root: Path, **env):
    bin_dir = root / 'bin'; bin_dir.mkdir(exist_ok=True)
    (bin_dir / 'codesign').write_text(STUB); (bin_dir / 'codesign').chmod(0o755)
    log = root / 'calls.log'; log.write_text('')
    for leftover in root.glob('calls.log.*'): leftover.unlink()
    app = make_app(root, with_appex=env.pop('with_appex', True))
    full = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', STUB_LOG=str(log), STUB_TEAM=FAKE_TEAM, TMPDIR=str(root))
    full.update({k: v for k, v in env.items()})
    result = subprocess.run([str(ROOT / 'scripts/sign-bundle.sh'), str(app), 'Apple Development: Stub Person (ABCDE12345)'], capture_output=True, text=True, env=full, cwd=ROOT)
    calls = [line.split(' ', 1)[1] for line in log.read_text().splitlines()]
    ents = {int(p.name.rsplit('.', 1)[1]): plistlib.loads(p.read_bytes()) for p in root.glob('calls.log.ents.*')}
    return result, calls, ents, app

def signing_calls(calls):
    out = []
    for index, call in enumerate(calls, start=1):
        if ' --sign ' in f' {call} ' and ' --entitlements ' in f' {call} ': out.append((index, call))
    return out

def self_test():
    group = f'{FAKE_TEAM}.local.native-music.development'
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        result, calls, ents, app = run_sign(root)
        assert result.returncode == 0, f'the good case must succeed: {result.stderr}'
        signs = signing_calls(calls)
        assert len(signs) == 2, f'exactly two final signatures (extension, app): {calls}'
        (first_index, first), (second_index, second) = signs
        assert 'NativeMusicWidget.appex' in first and 'NativeMusicWidget.appex' not in second.replace('YTMuse.app', '') or first.rstrip().endswith('NativeMusicWidget.appex'), 'the extension is signed first'
        assert first.rstrip().endswith('NativeMusicWidget.appex') and second.rstrip().endswith('YTMuse.app'), f'inner to outer: {signs}'
        identities = {re.search(r'--sign (.+?) (?:/|--)', c + ' ').group(1) if re.search(r'--sign (.+?) (?:/|--)', c + ' ') else None for _, c in signs}
        assert all('Apple Development: Stub Person (ABCDE12345)' in c for _, c in signs), 'both signed with the one identity'
        assert ents[first_index] == {'com.apple.security.app-sandbox': True, 'com.apple.security.application-groups': [group]}, f'the extension: sandbox and the expanded group only: {ents[first_index]}'
        assert ents[second_index] == {'com.apple.security.application-groups': [group]}, f'the app: the expanded group only: {ents[second_index]}'
        for plist in (app / 'Contents/Info.plist', app / 'Contents/PlugIns/NativeMusicWidget.appex/Contents/Info.plist'):
            assert plistlib.loads(plist.read_bytes())['YTMuseAppGroup'] == group, f'{plist.name} carries the group the code reads'
        assert FAKE_TEAM not in result.stdout + result.stderr, 'the team id is never printed'
        assert not any('$(TeamIdentifierPrefix)' in str(e) for e in ents.values()), 'no unexpanded placeholder reaches codesign'
        probe = [c for c in calls if 'probe.appex' in c and '--sign' in c]
        assert probe and not any('--entitlements' in c for c in probe), 'the team is learned from a throwaway COPY signed without entitlements'
        # The repository's own templates never carry a team.
        for template in (ROOT / 'App/NativeMusic.entitlements', ROOT / 'Extensions/NativeMusicWidget.entitlements'):
            text = template.read_text()
            assert '$(TeamIdentifierPrefix)local.native-music.development' in text and not re.search(r'\b[A-Z0-9]{10}\.local\.native-music', text), f'{template.name} holds the placeholder, not a team'
    import importlib.util
    spec = importlib.util.spec_from_file_location('check_intents', ROOT / 'scripts/check-intents.py'); check_intents = importlib.util.module_from_spec(spec); spec.loader.exec_module(check_intents)
    adhoc_run = lambda args, path: (0, b'') if args == ['-dv'] else ((0, b'TeamIdentifier=not set\n') if args == ['-dvv'] else (0, plistlib.dumps({})))
    failures = {
        'an identity with no Team ID': (dict(STUB_TEAM=''), False),
        'a team that is not ten characters': (dict(STUB_TEAM='SHORT'), False),
        'an extension that ended up in another team': (dict(STUB_APPEX_TEAM='OTHERTEAM2'), True),
        'an app that ended up in another team': (dict(STUB_APP_TEAM='OTHERTEAM2'), True),
        'an identity that is not Apple Development': (dict(STUB_AUTHORITY='Developer ID Application: Someone (ABCDE12345)'), True),
        'a signature that does not verify': (dict(STUB_VERIFY_FAIL='1'), True),
        'the extension signature failing midway': (dict(STUB_FAIL_ON='.appex'), True),
        'the app signature failing midway, after the extension was signed': (dict(STUB_FAIL_ON='YTMuse.app'), True),
    }
    for name, (env, touched) in failures.items():
        with tempfile.TemporaryDirectory() as t:
            result, calls, ents, app = run_sign(Path(t), **env)
            assert result.returncode != 0, f'{name} must fail'
            assert FAKE_TEAM not in result.stdout + result.stderr, f'{name}: the team is never printed'
            appex = app / 'Contents/PlugIns/NativeMusicWidget.appex'
            if touched:
                # The EXIT trap restored an AD-HOC bundle: the extension removed, the group key back to the build variable, the app signed ad hoc with the ad-hoc entitlements last.
                assert not appex.exists(), f'{name}: the embedded extension is removed by the restore'
                assert plistlib.loads((app / 'Contents/Info.plist').read_bytes())['YTMuseAppGroup'] == '$(TeamIdentifierPrefix)local.native-music.development', f'{name}: the group key is back to the placeholder'
                last = calls[-1]
                assert ' --sign - ' in f' {last} ' and 'App/NativeMusic-adhoc.entitlements' in last and last.rstrip().endswith('YTMuse.app'), f'{name}: the last call ad-hoc-signs the app with no group: {last}'
                assert check_intents.check_embedding(app, adhoc_run) == [], f'{name}: the restored bundle passes the ad-hoc rule of check-intents.py'
            else:
                assert appex.exists() and not [c for c in calls if ' --sign - ' in f' {c} '], f'{name}: nothing had been changed, so nothing is restored'
    with tempfile.TemporaryDirectory() as t:
        result, calls, ents, app = run_sign(Path(t), with_appex=False)
        assert result.returncode == 66 and not signing_calls(calls), 'a bundle without the extension is refused before anything is signed'
    # build.sh embeds only with an identity.
    text = (ROOT / 'scripts/build.sh').read_text()
    assert 'embed=NO; [[ -n "$identity" ]] && embed=YES' in text and './scripts/sign-bundle.sh "$app" "$identity"' in text, 'build.sh embeds only for an identity and signs through sign-bundle.sh'
    assert 'YTMUSE_EMBED_WIDGET:-NO' in (ROOT / 'scripts/embed-widget.sh').read_text(), 'the embed phase defaults to NO'
    assert 'codesign' not in re.sub(r'#.*', '', (ROOT / 'scripts/embed-widget.sh').read_text()), 'the embed phase signs nothing'
    print('self-test: PASS  inner-to-outer signing with one identity, the prefix filled in from the team and never printed, a refused identity or mismatched team restores ad hoc, no extension no signing; build.sh embeds only for an identity')

if __name__ == '__main__':
    if '--self-test' in sys.argv: self_test()
    else: print(__doc__)
