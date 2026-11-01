#!/usr/bin/env python3
"""W26 mutation matrix (T26). Serial, one scratch copy, one build/test process at a time, compiler jobs capped through scripts/bin.

Rules (Docs/Harness-Brief.md, "Memory: share the Mac" and real-data safety):
  * the scratch copy lives under the system temp directory with this run's own id; it is deleted at the end (and its .build after every mutation when
    --prune is given); nothing outside it is written, and no production path, store, Keychain item or app preference is ever read or written;
  * no mutation runs the app: only `swift test` over the T26 classes;
  * every mutation carries its EXPECTED outcome. CONTROL-SURVIVE is a mutation the suite has no reason to catch (a label no test reads); CONTROL-CAUGHT
    is one it must catch. A harness that reports everything caught, or one control wrong, is INVALID, not a pass;
  * a baseline run (no mutation) must be green with the expected test count first; "error: ..." (a build failure) scores BUILD-ERROR, never "caught".

Usage: run-mutations.py [--dry-run] [--only ID ...] [--prune]
"""
import json, os, re, shutil, subprocess, sys, tempfile, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
RUN = uuid.uuid4().hex[:8]
FILTER = 'LinkPolicyTests|CanonicalLinkTests|ShortcutTableTests|GlobalShortcutTests|ScriptDispatcherTests|ScriptingShellTests|ScriptingDictionaryTests|ScriptingExampleTests|LaunchGuardTests|TestPreferencesStayInMemoryTests|ShareTests|HandoffTests|NotificationOptInTests|PermissionDefaultsTests|IntegrationLocalizationTests'
SI = 'Packages/NativeMusic/Sources/SystemIntegration/'
AS = 'Packages/NativeMusic/Sources/AppShell/'

# (id, expected, file, old, new, what)
M = [
 ('C1', 'SURVIVE', SI + 'Shortcuts.swift', 'case "return": "↩"; case "escape": "⎋"; case "tab": "⇥"', 'case "return": "↩"; case "escape": "⎋"; case "tab": "⇤"', 'CONTROL-SURVIVE: the label of the Tab key, which nothing renders or tests'),
 ('C2', 'CAUGHT', SI + 'Shortcuts.swift', 'case .notWhileEditingText: focus != .textEditing && focus != .webContent', 'case .notWhileEditingText: focus != .webContent', 'CONTROL-CAUGHT: Command-Arrow no longer gives way to a text field (also via the router rule below)'),
 ('L1', 'CAUGHT', SI + 'Links.swift', 'case "https": return parseWeb(host: host, components: components)', 'case "https", "http": return parseWeb(host: host, components: components)', 'accept http'),
 ('L2', 'CAUGHT', SI + 'Links.swift', 'guard components.port == nil else { return .failure(.port) }', '', 'allow a port'),
 ('L3', 'CAUGHT', SI + 'Links.swift', 'guard isMusic || youtubeHosts.contains(host) || host == shortHost else { return .failure(.host) }', 'guard isMusic || host.hasSuffix("youtube.com") || host == shortHost else { return .failure(.host) }', 'accept any host ending in youtube.com'),
 ('L4', 'CAUGHT', SI + 'Links.swift', 'guard components.query == nil, components.queryItems == nil else { return .failure(.query) }', '', 'allow a query (action parameters) on the app scheme'),
 ('L5', 'CAUGHT', SI + 'Links.swift', 'guard !components.percentEncodedPath.contains("%"), !(components.percentEncodedHost ?? "").contains("%"), !(components.percentEncodedQuery ?? "").contains("%") else { return .failure(.encoded) }', '', 'allow percent-encoding'),
 ('L6', 'CAUGHT', SI + 'Links.swift', 'static func isVideoID(_ text: String) -> Bool { text.utf8.count == 11 && allURLSafe(text) }', 'static func isVideoID(_ text: String) -> Bool { text.utf8.count >= 1 && allURLSafe(text) }', 'any-length video id'),
 ('L7', 'CAUGHT', SI + 'Links.swift', 'let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " \\t\\r\\n"))', 'let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)', 'trim zero-width and no-break characters like white space'),
 ('L8', 'CAUGHT', SI + 'Links.swift', 'guard components.fragment == nil else { return .failure(.fragment) }', '', 'allow a fragment'),
 ('L9', 'CAUGHT', SI + 'Links.swift', 'if let list = values["list"], !LinkShapes.isPlaylistID(list) { return .failure(.identifier) }', '', 'accept any list value riding on a watch link'),
 ('S1', 'CAUGHT', SI + 'Shortcuts.swift', 'if focus == .textEditing || focus == .webContent { return .deliverToFocus }', '', 'the router no longer defers to an editing text field'),
 ('S2', 'CAUGHT', SI + 'Shortcuts.swift', 'guard !chord.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .needsModifier }', '', 'a global shortcut needs no modifier'),
 ('S3', 'CAUGHT', SI + 'Shortcuts.swift', 'if let name = editing[chord] { return .standardEditing(name) }', '', 'a global shortcut may take a standard editing chord'),
 ('S4', 'CAUGHT', SI + 'Shortcuts.swift', 'return GlobalShortcutPolicy.validate(chord, for: action, assigned: [:]) == nil ? chord : nil', 'return chord', 'a stored chord is registered without being re-validated'),
 ('S5', 'CAUGHT', SI + 'Shortcuts.swift', 'guard let data = defaults.data(forKey: key(action)), let chord = try? JSONDecoder().decode(KeyChord.self, from: data) else { return nil }', 'guard let data = defaults.data(forKey: key(action)), let chord = try? JSONDecoder().decode(KeyChord.self, from: data) else { return action == .showHide ? KeyChord("h", [.control, .option]) : nil }', 'a default global shortcut is assigned'),
 ('S6', 'CAUGHT', AS + 'Integration/ShortcutRouting.swift', 'guard candidate.sheetParent == nil, let role = role(candidate) else { return false }', 'guard let role = role(candidate) else { return false }', 'a sheet counts as a playback window'),
 ('S7', 'CAUGHT', AS + 'Integration/ShortcutRouting.swift', 'if event.isARepeat, !Self.repeats(action) { return nil }', '', 'holding Space repeats the toggle'),
 ('S8', 'CAUGHT', AS + 'Integration/ShortcutRouting.swift', 'guard let router else { return event }\n        return router.handle(event, in: window)', 'guard let router else { return event }\n        return router.handle(event, in: window) ?? event', 'the monitor turns a consumed event back into a pass-through (the first UI run found this)'),
 ('R1', 'CAUGHT', AS + 'Integration/ShortcutRouting.swift', 'MainActor.assumeIsolated { RoutedEvent(event: Self.monitorResult(of: router, for: event)) }.event', 'MainActor.assumeIsolated { RoutedEvent(event: Self.monitorResult(of: router, for: event) ?? event) }.event', 'REWORK 1: the consumed-event bug put back in the closure AppKit calls (the review found it survived)'),
 ('Q1', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'origin = .appleScript', 'origin = .menu', 'REWORK 1: the script queue command is identified as a menu action (the review found it survived)'),
 ('G1', 'CAUGHT', SI + 'Shortcuts.swift', 'if let title = ShortcutTable.menuTitle(for: chord) { return', 'if let title = ShortcutTable.entry(for: chord)?.title { return', 'REWORK 1: the app menu shortcuts outside the table are accepted as global shortcuts'),
 ('G2', 'CAUGHT', SI + 'Shortcuts.swift', 'chord.modifiers.isSubset(of: [.option, .shift]) { return .entersText }', 'chord.modifiers.isSubset(of: [.option, .shift]) { return nil }', 'REWORK 1: Option-only letters accepted'),
 ('G3', 'CAUGHT', SI + 'Shortcuts.swift', 'if let name = textSystemName(chord) { return .standardEditing(name) }', '', 'REWORK 1: Control-letter and shifted-arrow text chords accepted'),
 ('G4', 'CAUGHT', SI + 'Shortcuts.swift', 'else { failures[action] = .couldNotRegister }', 'else { failures[action] = .takenBySystemSetting }', 'REWORK 1: a refused registration reported as macOS having the shortcut'),
 ('G5', 'CAUGHT', SI + 'Shortcuts.swift', '"f6": 97,', '"f6": 98,', 'REWORK 1: two keys share a key code'),
 ('D1', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', r'p("\\bAppli", "cation\\s*', r'p("\\bZZ", "ZZ\\s*', 'REWORK 1: the launch guard stops seeing JXA application addressing'),
 ('D2', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', 'if !path.hasPrefix(uiTestDirectory), code.range', 'if false, code.range', 'REWORK 1: the launch guard allows the process-id descriptor everywhere'),
 ('D4', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'static func destination(from text: String?) -> Result<LinkDestination, LinkRefusal>? { text.map { LinkPolicy.parse(text: $0) } }', 'static func destination(from text: String?) -> Result<LinkDestination, LinkRefusal>? { text.map { _ in .failure(.notALink) } }', 'REWORK 1: the window drop handler refuses every link'),
 ('E1', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', '("absolute-path open", p("/usr/bin/", "open\\\\b"), false),', '("absolute-path open", p("ZZ", "ZZ"), false),', 'REWORK 2: the launch guard stops seeing the absolute path of the open command'),
 ('E2', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', 'workspaceViaVariable(code) { result.append', 'false { result.append', 'REWORK 2: the launch guard stops following an NSWorkspace variable'),
 ('E3', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', '("UI test addressed by bundle identifier", p("XCUIAppli", "cation', '("UI test addressed by bundle identifier", p("ZZ", "ZZ', 'REWORK 2: the launch guard allows the UI-test application to be addressed by bundle identifier'),
 ('E4', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', 'guard scriptExtensions.contains(ext) || ext.isEmpty else { continue }', 'guard scriptExtensions.contains(ext) else { continue }', 'REWORK 2: the launch guard skips extensionless files'),
 ('E5', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', 'if sha256(of: text) == entry.sha256 { granted = entry.rules }', 'if true { granted = entry.rules }', 'REWORK 2: an edited allow-listed file keeps its exemption'),
 ('E6', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', '["OSA command line"],\n                                    "reads window positions', '["OSA command line", "addresses an application by tell"],\n                                    "reads window positions', 'REWORK 2: the System Events file is exempt from application targeting wholesale'),
 ('E7', 'CAUGHT', 'Packages/NativeMusic/Tests/PlaybackTests/Integration/LaunchGuardTests.swift', 'pattern += "(?!', 'pattern += "(?:|', 'REWORK 2: the System Events narrowing stops narrowing'),
 ('P1', 'CAUGHT', SI + 'Shortcuts.swift', 'KeyChord("space", .option): "typing a no-break space", KeyChord("space", [.option, .shift]): "typing a no-break space",', '', 'REWORK 2: Option-Space accepted as a global shortcut'),
 ('P2', 'CAUGHT', SI + 'Shortcuts.swift', 'KeyChord(";", .command): "Check Spelling",', '', 'REWORK 2: Command-; accepted as a global shortcut'),
 ('A1', 'CAUGHT', SI + 'Scripting.swift', 'guard position.isFinite, position >= 0, position <= 86_400 else { return .invalidArgument }', '', 'a seek to NaN or a negative time reaches the target'),
 ('A2', 'CAUGHT', SI + 'Scripting.swift', 'guard case .success(.item(let item)) = LinkPolicy.parse(text: text), item.kind == .song else { return .invalidLink }', 'guard case .success(.item(let item)) = LinkPolicy.parse(text: text) else { return .invalidLink }', 'queue insertion accepts any item kind'),
 ('A3', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'case .refused: return .notAllowedNow(playback.remoteReason(command.kind) ?? String(localized: "That command is not available right now."))', 'case .refused: return nil', 'a refused command (an advertisement) reports success to the script'),
 ('A4', 'CAUGHT', 'Resources/YTMuse.sdef', '<cocoa class="YTMuseNextTrackCommand"/>', '<cocoa class="YTMuseNextTrackCommandX"/>', 'the dictionary names a class that does not exist'),
 ('A5', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'if let player = playback.music, WebMusicQueueSummary.isActive(player) {\n            return .queueNotEditable', 'if false {\n            return .queueNotEditable', 'queue insertion pretends YouTube Music accepts it'),
 ('H1', 'CAUGHT', SI + 'HandoffAndNotifications.swift', 'public static let advertisedKinds: Set<LinkItemKind> = [.song, .album, .artist, .podcast, .episode]', 'public static let advertisedKinds: Set<LinkItemKind> = [.song, .album, .artist, .podcast, .episode, .playlist]', 'Handoff advertises playlists'),
 ('H2', 'CAUGHT', SI + 'HandoffAndNotifications.swift', 'activity.userInfo = userInfo', 'activity.userInfo = userInfo; activity.title = "YTMuse"', 'Handoff carries a title'),
 ('H3', 'CAUGHT', SI + 'Links.swift', 'case .song: components.path = "/watch"; components.queryItems = [URLQueryItem(name: "v", value: item.identifier)]', 'case .song: components.path = "/watch"; components.queryItems = [URLQueryItem(name: "v", value: item.identifier), URLQueryItem(name: "feature", value: "share")]', 'the share link carries a tracking parameter'),
 ('N1', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'if state == .authorized { preferences.set(true, forKey: Self.key); isOn = true }', 'if true { preferences.set(true, forKey: Self.key); isOn = true }', 'the toggle turns on although permission was refused'),
 ('N2', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'guard isOn, let notification = SongNotification.make', 'guard let notification = SongNotification.make', 'notifications post while the feature is off'),
 ('N3', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'var state = await service.authorization()\n        if state == .notDetermined { state = await service.requestAuthorization() }', 'var state = await service.requestAuthorization()', 'the toggle asks for permission even when already decided'),
 ('N4', 'CAUGHT', SI + 'HandoffAndNotifications.swift', 'guard !isAdvertisement, let title', 'guard let title', 'an advertisement is announced'),
 ('F1', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'if isolated { return IntegrationFacilities() }', '', 'an isolated launch gets the system registrar and notification center'),
 ('F2', 'CAUGHT', AS + 'Integration/ShellIntegration.swift', 'if let url = currentShareLink { facilities.sharing.present(url) }', 'facilities.sharing.present(currentShareLink ?? URL(string: "https://music.youtube.com/")!)', 'Share presents something when there is no song link'),
]

def run(cmd, cwd, env, timeout):
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)

def main():
    dry = '--dry-run' in sys.argv; prune = '--prune' in sys.argv
    only = [x for i, a in enumerate(sys.argv) if i and sys.argv[i - 1] == '--only' for x in a.split(',')]   # repeat the flag or give a comma list
    # Every mutation must apply exactly once; a mutation that matches nothing would score as SURVIVED and look like a coverage gap.
    for mid, exp, rel, old, new, what in M:
        text = (ROOT / rel).read_text()
        assert text.count(old) == 1, f'{mid}: the text to mutate matches {text.count(old)} times in {rel}'
        assert old != new, f'{mid}: a no-op mutation'
    print(f'selected: {only or "all"}')
    print(f'{len(M)} mutations, each applies exactly once; expected: {sum(1 for m in M if m[1] == "SURVIVE")} survive, {sum(1 for m in M if m[1] == "CAUGHT")} caught')
    if dry: return 0
    scratch = Path(tempfile.gettempdir()) / f'ytmuse-w26-mutation-{RUN}'
    results = []
    # One build or test process at a time in this lane: the UI job holds the same lock while its suites build and run.
    lock = Path(os.environ.get('W26_BUILD_LOCK', '/tmp/ytmuse-w26-build.lockdir'))
    while True:
        try: lock.mkdir(); break
        except FileExistsError: time.sleep(15)
    try:
        for part in ['Packages/NativeMusic', 'App', 'Docs', 'Resources', 'scripts', 'Tests', 'Fixtures', 'Tools', 'Extensions', 'artifacts/harness/nodes/W26', 'artifacts/harness/nodes/W09/rework-11', 'toolchain.json']:
            src = ROOT / part
            dst = scratch / part
            dst.parent.mkdir(parents=True, exist_ok=True)
            if src.is_dir(): shutil.copytree(src, dst, ignore=shutil.ignore_patterns('.build', '.swiftpm', 'DerivedData', '*.xcresult'))
            else: shutil.copy2(src, dst)
        env = dict(os.environ); env['PATH'] = str(scratch / 'scripts/bin') + ':' + env['PATH']
        def tests():
            # Swift Testing does not rebuild on a stale object timestamp of a same-size edit: clear module caches of the touched file's module is not needed with SwiftPM, but .pyc-like staleness is avoided by touching.
            r = run(['swift', 'test', '--package-path', 'Packages/NativeMusic', '--filter', FILTER], scratch, env, 3600)
            out = re.sub(r'\x1b\[[0-9;]*m', '', r.stdout + r.stderr)
            built = 'error:' in out and 'Test run with' not in out
            ran = re.findall(r'Test run with (\d+) tests? in (\d+) suites?', out)
            failed = len(re.findall(r'✘ Test .* recorded an issue|Test Case .* failed', out))
            return r.returncode, built, ran, failed, out
        print('baseline (no mutation) ...', flush=True)
        code, built, ran, failed, out = tests()
        baseline = {'exit': code, 'ran': ran, 'failed': failed}
        print(' ', baseline, flush=True)
        if code != 0 or not ran or built or failed:
            print('INVALID: the baseline is not green (a harness that cannot run reports everything "caught")'); (scratch / 'baseline.log').write_text(out[-6000:]); print('\n'.join(l[:300] for l in out.splitlines() if l.startswith('✘') or l.startswith('↳') or 'Expectation' in l)[:4000]); return 2
        for mid, exp, rel, old, new, what in M:
            if only and mid not in only: continue
            path = scratch / rel
            original = path.read_text()
            path.write_text(original.replace(old, new, 1)); os.utime(path, None)
            t0 = time.time()
            code, built, ran, failed, out = tests()
            path.write_text(original); os.utime(path, None)
            outcome = 'BUILD-ERROR' if built else ('CAUGHT' if code != 0 else 'SURVIVED')
            ok = (outcome == 'CAUGHT' and exp == 'CAUGHT') or (outcome == 'SURVIVED' and exp == 'SURVIVE')
            first = next((l.strip()[:200] for l in out.splitlines() if '✘ Test' in l and 'recorded an issue' in l), '')
            results.append({'id': mid, 'expected': exp, 'outcome': outcome, 'as_expected': ok, 'what': what, 'seconds': round(time.time() - t0), 'first_failure': first})
            print(f'{mid:3} {exp:8} -> {outcome:11} {"ok " if ok else "MISMATCH"} {what}', flush=True)
            if prune: shutil.rmtree(scratch / 'Packages/NativeMusic/.build', ignore_errors=True)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
        try: lock.rmdir()
        except OSError: pass
    controls_ok = all(r['as_expected'] for r in results if r['id'] in ('C1', 'C2'))
    summary = {'run': RUN, 'baseline': baseline, 'results': results, 'caught': sum(1 for r in results if r['outcome'] == 'CAUGHT'), 'survived': sum(1 for r in results if r['outcome'] == 'SURVIVED'),
               'build_errors': sum(1 for r in results if r['outcome'] == 'BUILD-ERROR'), 'mismatches': [r['id'] for r in results if not r['as_expected']], 'controls_valid': controls_ok}
    (ROOT / 'artifacts/harness/nodes/W26/mutation/results.json').write_text(json.dumps(summary, indent=1) + '\n')
    print(json.dumps({k: v for k, v in summary.items() if k != 'results'}))
    return 0 if controls_ok and not summary['mismatches'] and not summary['build_errors'] else 1

if __name__ == '__main__':
    sys.exit(main())
