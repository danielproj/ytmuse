#!/usr/bin/env python3
"""Appends to Resources/L10N/core-en.txt every translatable source key that is not in it yet (new ids, never renumbered), so a string added to the sources
reaches the catalog and the seeds' to-do list. Prints the new ids. `--check` fails when there is anything to add."""
import json, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import source_keys as sk
ROOT = sk.ROOT
core = ROOT / 'Resources/L10N/core-en.txt'
lines = [l for l in core.read_text().splitlines() if l.strip()]
have = set()
for l in lines:
    ident, text = l.split('|', 1)
    have.add(text.split('\t')[-1].split(':', 1)[1] if ident.startswith('P') else text)
catalog = json.loads((ROOT / 'Resources/Localizable.xcstrings').read_text())['strings']
extra = set((ROOT / 'Resources/L10N/extra-keys.txt').read_text().splitlines())
excluded = {l.split('\t')[0] for l in (ROOT / 'Resources/L10N/excluded-keys.txt').read_text().splitlines()}
new = []
for key in sorted(set(sk.source_keys()) | extra):
    if key in have or key in excluded or '\u0000' in key or '\\(' in key or len(key.strip()) < 2 or sk.is_qa(key): continue
    if key == 'Some labels change after you relaunch YTMuse.': continue
    new.append(key)
if '--check' in sys.argv:
    print('universe is current' if not new else f'{len(new)} source keys are not in core-en.txt: {new[:5]}')
    sys.exit(1 if new else 0)
maxid = max(int(l.split('|')[0]) for l in lines if l.split('|')[0].isdigit())
maxq = max([int(l.split('|')[0][1:]) for l in lines if l.startswith('Q')] or [0])
plain, counted = [], []
for key in new:
    if '%lld' in key: maxq += 1; counted.append(f'Q{maxq}|{key}')
    else: maxid += 1; plain.append(f'{maxid}|{key}')
simple = [l for l in lines if l.split('|')[0].isdigit()]; rest = [l for l in lines if not l.split('|')[0].isdigit()]
core.write_text('\n'.join(simple + plain + rest + counted) + '\n')
print(f'added {len(plain)} plain ({maxid - len(plain) + 1}..{maxid}) and {len(counted)} counted keys')
