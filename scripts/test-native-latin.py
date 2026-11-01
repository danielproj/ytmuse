#!/usr/bin/env python3
"""Reversible, enabled-input-source setup for Latin XCTest fixtures only.
Catchable INT/TERM/HUP preserve the first outcome while teardown, restoration,
verification and atomic receipt writing finish. SIGKILL/power loss cannot be handled.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


def ignore_signals():
    # Ignored dispositions also protect restore helpers from terminal group signals.
    # The normal handler never raises, including between these three assignments.
    for sig in SIGNALS:
        signal.signal(sig, signal.SIG_IGN)


def exit_status(returncode):
    return returncode if returncode >= 0 else 128 - returncode


def main():
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    helper = root / '.build/v01-input-source'
    helper.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['swiftc', 'Tests/DesignSystem/TestInputSource.swift', '-o', str(helper)], check=True)

    def source(*args):
        return subprocess.check_output([str(helper), *args], text=True).strip()

    original = source()  # No source has been changed if this read fails.
    receipt = {'original': original, 'testSource': None, 'selected': False, 'restored': False,
               'uncatchableInterruptionCovered': False}
    receipt_path = Path(os.environ.get('INPUT_SOURCE_RECEIPT', '.build/v01-input-source.json'))
    receipt_path.parent.mkdir(parents=True, exist_ok=True)

    def write_receipt():
        temporary = receipt_path.with_name(receipt_path.name + f'.{os.getpid()}.tmp')
        temporary.write_text(json.dumps(receipt, indent=2) + '\n')
        temporary.replace(receipt_path)

    code = 75
    child = None
    first_signal = None

    def interrupted(signum, frame):
        nonlocal first_signal
        if first_signal is None:
            first_signal = signum
        # Never raise here: a signal can arrive during subprocess setup or cleanup.

    def record_interruption():
        receipt.update(outcome='interrupted', interruptionSignal=first_signal)
        return 128 + first_signal

    for sig in SIGNALS:
        signal.signal(sig, interrupted)
    try:
        receipt['testSource'] = source('--ascii')
        receipt['selected'] = True
        write_receipt()
        if first_signal is not None:
            code = record_interruption()
        else:
            child = subprocess.Popen(sys.argv[1:])
            while True:
                if first_signal is not None:
                    code = record_interruption()
                    break
                try:
                    child.wait(timeout=0.1)
                except subprocess.TimeoutExpired:
                    continue
                if first_signal is not None:
                    code = record_interruption()
                else:
                    code = exit_status(child.returncode)
                    receipt.update(commandExitCode=child.returncode, outcome='command_exit')
                break
    except subprocess.CalledProcessError as error:
        # The helper's 75 means no enabled/selectable ASCII source or OS refusal.
        code = 75 if error.returncode == 75 else exit_status(error.returncode)
        receipt.update(outcome='environment_blocked' if code == 75 else 'setup_failed',
                       helperExitCode=error.returncode)
        if first_signal is not None:
            code = record_interruption()
        print('Native test input source unavailable.' if code == 75 else 'Native test setup failed.', file=sys.stderr)
    except OSError:
        code = 1
        receipt['outcome'] = 'command_launch_failed'
        if first_signal is not None:
            code = record_interruption()
        print('Native test command could not launch.', file=sys.stderr)
    finally:
        # Includes the complete xcodebuild teardown wait, every restore/verify call,
        # and receipt serialization/replace. A later signal cannot replace the outcome.
        ignore_signals()
        receipt['outcomeExitCode'] = code
        cleanup_errors = []
        if child is not None and child.poll() is None:
            try:
                child.terminate()
                try:
                    child.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            except ProcessLookupError:
                child.wait()  # The child exited between poll and terminate/kill.
            except OSError:
                cleanup_errors.append('child_teardown_failed')
        try:
            source(original)
            # TIS selection can settle asynchronously across processes. Require
            # three consecutive fresh helper reads, rather than its local select result.
            receipt['verificationReads'] = []
            consecutive = 0
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and consecutive < 3:
                time.sleep(0.1)
                current = source()
                receipt['verificationReads'].append(current)
                consecutive = consecutive + 1 if current == original else 0
            receipt['final'] = receipt['verificationReads'][-1]
            receipt['restored'] = consecutive == 3
        except (OSError, subprocess.CalledProcessError):
            cleanup_errors.append('source_restore_failed')
        if not receipt['restored']:
            cleanup_errors.append('source_restore_not_verified')
        if cleanup_errors:
            receipt['cleanupErrors'] = cleanup_errors
            code = 70
        receipt['exitCode'] = code
        write_receipt()
    return code


if __name__ == '__main__':
    sys.exit(main())
