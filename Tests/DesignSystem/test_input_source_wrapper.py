#!/usr/bin/env python3
"""Isolated wrapper controls. Fake source state only; no Carbon/TIS or UI changes."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(sys.argv[1]).resolve()
OUT.mkdir(parents=True, exist_ok=True)
TEMPLATE = ROOT / 'artifacts/harness/nodes/V01/rework-2/critic/repro/input-source-wrapper/FakeTestInputSource.swift'

def wait_until(predicate, process, description):
    deadline = time.monotonic() + 20
    while not predicate():
        if process.poll() is not None or time.monotonic() > deadline:
            raise AssertionError(f'{description}: process exit={process.poll()}')
        time.sleep(.02)

results = []
with tempfile.TemporaryDirectory(prefix='v01-wrapper-controls-') as temporary:
    root = Path(temporary)
    (root / 'scripts').mkdir(); (root / 'Tests/DesignSystem').mkdir(parents=True)
    shutil.copyfile(ROOT / 'scripts/test-native-latin.py', root / 'scripts/test-native-latin.py')
    state = root / 'state'; stage = root / 'stage'
    fake = TEMPLATE.read_text().replace('/tmp/v01-critic-repro/latin/state.txt', str(state))
    fake = fake.replace('if mode == "slowrestore" { sleep(3) }',
        'try! "restoring".write(toFile: "' + str(stage) + '", atomically: true, encoding: .utf8)\nif mode == "slowrestore" { sleep(2) }')
    (root / 'Tests/DesignSystem/TestInputSource.swift').write_text(fake)
    cases = [('success', '', 0), ('failure', '', 7), ('refusal', 'noascii', 75),
             ('sigterm', 'slowrestore', 143), ('sighup', 'slowrestore', 129),
             ('double-signal-restore', 'slowrestore', 130), ('double-signal-teardown', '', 143),
             ('signals-final-receipt', 'slowrestore', 7)]
    for name, mode, expected in cases:
        state.write_text('fake.Original'); stage.unlink(missing_ok=True)
        receipt = root / 'receipt.json'; receipt.unlink(missing_ok=True)
        child_stage = root / 'child-stage'; child_stage.unlink(missing_ok=True)
        write_stage = root / 'write-stage'; write_stage.unlink(missing_ok=True)
        env = os.environ.copy(); env.update(FAKE_MODE=mode, INPUT_SOURCE_RECEIPT=str(receipt))
        if name in ('success', 'refusal'): command = [sys.executable, '-c', 'pass']
        elif name in ('failure', 'signals-final-receipt'): command = [sys.executable, '-c', 'raise SystemExit(7)']
        elif name == 'double-signal-teardown':
            command = [sys.executable, '-c', f'''import signal,time,pathlib
sigs=(signal.SIGINT,signal.SIGTERM,signal.SIGHUP)
def stop(sig,frame):
 for s in sigs:signal.signal(s,signal.SIG_IGN)
 pathlib.Path({str(child_stage)!r}).write_text('teardown')
 time.sleep(2)
 raise SystemExit(0)
for s in sigs:signal.signal(s,stop)
pathlib.Path({str(child_stage)!r}).write_text('ready')
time.sleep(30)
''']
        else: command = [sys.executable, '-c', 'import time;time.sleep(30)']
        wrapper = root / 'scripts/test-native-latin.py'
        # Delay the final atomic receipt write to exercise signals in that exact window.
        if name == 'signals-final-receipt':
            entry = root / 'receipt-write-entry.py'
            entry.write_text(f'''import pathlib,runpy,sys,time
write=pathlib.Path.write_text
def delayed(self,text,*args,**kwargs):
 if '"restored": true' in text:
  write(pathlib.Path({str(write_stage)!r}),'writing')
  time.sleep(2)
 return write(self,text,*args,**kwargs)
pathlib.Path.write_text=delayed
sys.argv=[{str(wrapper)!r}]+sys.argv[1:]
runpy.run_path({str(wrapper)!r},run_name='__main__')
''')
        else: entry = wrapper
        with (OUT / (name + '.log')).open('w') as log:
            process = subprocess.Popen([sys.executable, '-I', str(entry), *command], env=env,
                                       stdout=log, stderr=log, start_new_session=True)
            if name.startswith(('sigterm', 'sighup', 'double-signal')):
                wait_until(receipt.exists, process, 'selection receipt')
                if name == 'double-signal-teardown':
                    wait_until(lambda: child_stage.exists() and child_stage.read_text()=='ready', process, 'child ready')
                first = signal.SIGHUP if name == 'sighup' else signal.SIGINT if name=='double-signal-restore' else signal.SIGTERM
                os.killpg(process.pid, first)
                if name == 'double-signal-restore':
                    wait_until(stage.exists, process, 'restore started')
                    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT): os.killpg(process.pid, sig)
                elif name == 'double-signal-teardown':
                    wait_until(lambda: child_stage.exists() and child_stage.read_text()=='teardown', process, 'child teardown started')
                    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM): os.killpg(process.pid, sig)
            elif name == 'signals-final-receipt':
                wait_until(write_stage.exists, process, 'final receipt write started')
                for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM): os.killpg(process.pid, sig)
            code = process.wait(timeout=25)
        record = json.loads(receipt.read_text())
        final_state = state.read_text()
        assert code == expected, (name, code, expected)
        assert record['exitCode'] == expected and record['outcomeExitCode'] == expected, (name, record)
        assert record['restored'] and record['final'] == 'fake.Original' and final_state == 'fake.Original'
        assert str(wrapper) not in (OUT / (name + '.log')).read_text(), name  # Child SIGINT tracebacks are separate outcomes.
        (OUT / (name + '.json')).write_text(json.dumps(record, indent=2)+'\n')
        results.append({'case': name, 'exitCode': code, 'expectedExitCode': expected, 'restored': True, 'state': final_state})
(OUT / 'summary.json').write_text(json.dumps(results, indent=2)+'\n')
print(f'PASS: {len(results)} fake-helper success/failure/refusal/signal/cleanup controls')
