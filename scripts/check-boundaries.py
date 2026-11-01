#!/usr/bin/env python3
"""Fail closed on unapproved module edges or provider/UI contamination."""
import json, re, subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[1]
expected=json.loads((root/'scripts/module-dependencies.json').read_text())
package=json.loads(subprocess.check_output(['swift','package','--package-path',str(root/'Packages/NativeMusic'),'dump-package']))
actual={t['name']:[d['byName'][0] for d in t['dependencies']] for t in package['targets'] if t['type']=='regular'}
assert actual==expected, 'Declared module graph changed without boundary review'
visiting=set();done=set()
def visit(n):
 assert n not in visiting, f'Circular module dependency: {n}'
 if n in done:return
 visiting.add(n)
 for d in actual[n]:visit(d)
 visiting.remove(n);done.add(n)
for n in actual:visit(n)
for n in actual:
 for p in (root/'Packages/NativeMusic/Sources'/n).rglob('*.swift'):
  text=p.read_text()
  imports=set(re.findall(r'^import (\w+)',text,re.M))
  assert not ((imports & actual.keys())-set(actual[n])), f'Undeclared import: {p}'
  if n=='Domain':
   assert not imports & {'SwiftUI','AppKit','YouTubeMusicAdapter','FoundationNetworking'}, p
   assert not re.search(r'JSONDecoder|JSONSerialization|URLSession|continuationToken',text), p
  if n in {'Features','DesignSystem','AppShell'}:
   assert not imports & {'YouTubeMusicAdapter','StreamResolver'}, p
   assert not re.search(r'JSONDecoder|JSONSerialization|URLSession|https?://',text), p
print(f'PASS: {len(actual)} native module targets; acyclic approved graph; UI and Domain boundaries')

# Test-only providers and fixture support may never enter a production dependency closure.
test_targets={t['name'] for t in package['targets'] if t['type']=='test'}
for name, dependencies in actual.items():
 assert not set(dependencies) & test_targets, f'Production dependency on tests: {name}'
for base in [root/'Packages/NativeMusic/Sources', root/'App/Sources', root/'Extensions/Sources']:
 for path in base.rglob('*.swift'):
  assert not re.search(r'DomainContractTests|TestProvider|FixtureManifest|Fixtures/W02',path.read_text()), f'Test fixture leaked into production: {path}'
print('PASS: test providers and fixture manifests excluded from production sources/dependencies')
