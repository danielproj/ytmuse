#!/usr/bin/env python3
"""W24 rework 2 (T24.3): no compiled code reaches the system's intent-donation symbols.

The source guard (`IntentDonationGuardTests`) matches text, and text can be renamed around: `action.donate()`, `PausePlaybackIntent()()` and
`let p = PausePlaybackIntent(); try await p()` read differently but all call the same AppIntents symbols. This guard reads what the compiler actually
emitted: the UNDEFINED symbols of every object file (and any binary given), and fails on a reference into the AppIntents module to
  * `AppIntent.donate()` / `donate(result:)` and `IntentDonationIdentifier`,
  * `AppIntent.callAsFunction(donate:)` (an intent invoked like a function donates by default),
  * `IntentDonationManager`, `RelevantIntentManager` and the relevant-intent types.
Nothing the app's own `IntentHub.donate` defines matches: those symbols belong to SystemIntegration, not AppIntents.

Usage: check-intent-donations.py PATH... (directories are searched for *.o and *.dylib; a file is read as given)
       check-intent-donations.py --self-test   (compiles three plants and a clean file; each plant must be flagged, the clean file must not)
"""
import re, subprocess, sys, tempfile
from pathlib import Path

PATTERN = re.compile(r'10AppIntents\w*?(?:14callAsFunction|6donate|18DonationIdentifier)|10AppIntents\d+(?:IntentDonationManager|RelevantIntentManager|RelevantContext)|10AppIntents14RelevantIntent')


def undefined(path: Path):
    result = subprocess.run(['nm', '-u', str(path)], capture_output=True, text=True)
    return result.stdout.splitlines() if result.returncode == 0 else []


def scan(paths):
    files = []
    for root in map(Path, paths):
        if root.is_dir(): files += [p for p in root.rglob('*') if p.suffix in ('.o', '.dylib') or p.name in ('YTMuse',)]
        elif root.exists(): files.append(root)
    findings = []
    for file in files:
        hits = sorted({line.strip() for line in undefined(file) if PATTERN.search(line)})
        if hits: findings.append((file, hits))
    return files, findings


def self_test():
    sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
    header = ('import AppIntents\nstruct PausePlaybackIntent: AppIntent { static let title: LocalizedStringResource = "p"; '
              'func perform() async throws -> some IntentResult & ReturnsValue<String> { .result(value: "x") } }\n')
    plants = {
        'action_donate': 'func f() async throws { let action = PausePlaybackIntent(); _ = try await action.donate() }',
        'called_as_expression': 'func f() async throws { let _: String = try await PausePlaybackIntent()() }',
        'called_as_variable_p': 'func f() async throws { let p = PausePlaybackIntent(); let _: String = try await p() }',
        'donate_result': 'func f() async throws { _ = try await PausePlaybackIntent().donate(result: .result(value: "y")) }',
        'relevant': 'func f() async throws { try await RelevantIntentManager.shared.updateRelevantIntents([]) }',
        'manager': 'func f() { _ = IntentDonationManager.shared }',
    }
    clean = {'clean_perform': 'func f() async throws { _ = try await PausePlaybackIntent().perform() }'}
    with tempfile.TemporaryDirectory() as t:
        root = Path(t)
        for name, body in {**plants, **clean}.items():
            source = root / f'{name}.swift'; source.write_text(header + body + '\n')
            build = subprocess.run(['xcrun', 'swiftc', '-c', '-sdk', sdk, '-target', 'arm64-apple-macos27.0', '-swift-version', '6', str(source), '-o', str(root / f'{name}.o')], capture_output=True, text=True)
            assert build.returncode == 0, f'{name} did not compile: {build.stderr[:300]}'
        _, findings = scan([root])
        flagged = {f.stem for f, _ in findings}
        for name in plants: assert name in flagged, f'the plant {name} must be flagged'
        for name in clean: assert name not in flagged, f'{name} must pass'
    print(f'self-test: PASS  {len(plants)} plants flagged (including action.donate(), PausePlaybackIntent()() and p()), the clean file passes')


if __name__ == '__main__':
    if '--self-test' in sys.argv: self_test(); sys.exit(0)
    files, findings = scan([a for a in sys.argv[1:] if not a.startswith('--')])
    for file, hits in findings: print(f'FAIL: {file} references the system\'s donation symbols: {hits[:3]}')
    if findings: sys.exit(1)
    if not files: print('FAIL: nothing to scan: the build output is missing'); sys.exit(1)
    print(f'PASS: no donation symbol referenced by {len(files)} object files and binaries')
