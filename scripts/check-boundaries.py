#!/usr/bin/env python3
"""Fail closed on unapproved module edges or provider/UI contamination."""
import json, re, subprocess, sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
TEST_SUPPORT='TestSupport'
# TH5: the TestSupport rules are functions of the package description, so the self-test can feed them a planted description and a clean one.
def test_support_problems(package):
 problems=[]
 by_name={t['name']:t for t in package['targets']}
 if TEST_SUPPORT not in by_name or by_name[TEST_SUPPORT]['dependencies']!=[]: problems.append('TestSupport must exist and have no dependencies')
 for t in package['targets']:
  if t['type']!='test' and t['name']!=TEST_SUPPORT and any(d.get('byName',[None])[0]==TEST_SUPPORT for d in t['dependencies']):
   problems.append(f"{t['name']} ({t['type']}) depends on TestSupport; only test targets may")
 for product in package.get('products', []):
  if TEST_SUPPORT in product.get('targets', []): problems.append(f"product {product['name']} lists {TEST_SUPPORT}; it is a test-only library and must not be a product")
 return problems
def self_test():
 def target(name, kind='regular', dependencies=()): return {'name':name,'type':kind,'dependencies':[{'byName':[d,None]} for d in dependencies]}
 clean={'targets':[target(TEST_SUPPORT),target('Domain'),target('AppShell',dependencies=['Domain']),target('DomainTests','test',['Domain',TEST_SUPPORT])],
        'products':[{'name':'NativeMusicCore','targets':['Domain','AppShell']}]}
 assert test_support_problems(clean)==[], 'the clean description was flagged'
 def mutate(change):
  copy=json.loads(json.dumps(clean)); change(copy); return test_support_problems(copy)
 plants={
  'TestSupport listed in a library product': lambda p: p['products'].append({'name':'Shared','targets':['Domain',TEST_SUPPORT]}),
  'TestSupport as a product of its own': lambda p: p['products'].append({'name':TEST_SUPPORT,'targets':[TEST_SUPPORT]}),
  'a regular target depends on TestSupport': lambda p: p['targets'].append(target('Probe','regular',[TEST_SUPPORT])),
  'an executable target depends on TestSupport': lambda p: p['targets'].append(target('Tool','executable',[TEST_SUPPORT])),
  'TestSupport gains a dependency': lambda p: p['targets'][0]['dependencies'].append({'byName':['Domain',None]}),
  'TestSupport is missing': lambda p: p['targets'].pop(0),
 }
 for label, change in plants.items(): assert mutate(change), f'not caught: {label}'
 controls={
  'a new test target using TestSupport': lambda p: p['targets'].append(target('QueueTests','test',[TEST_SUPPORT])),
  'a new product that does not list it': lambda p: p['products'].append({'name':'Other','targets':['AppShell']}),
 }
 for label, change in controls.items(): assert not mutate(change), f'wrongly flagged: {label}'
 print(f'self-test: {len(plants)} TestSupport plants caught, {len(controls)} clean controls pass')
if sys.argv[1:]==['--self-test']:
 self_test(); sys.exit(0)
expected=json.loads((root/'scripts/module-dependencies.json').read_text())
package=json.loads(subprocess.check_output(['swift','package','--package-path',str(root/'Packages/NativeMusic'),'dump-package']))
# TH3: TestSupport (the test preference stores, Packages/NativeMusic/Tests/TestSupport) is a library target only so the test targets can share it. It is not part of the
# product, so it is not in the reviewed module graph (and not in the SBOM); it is checked separately below.
actual={t['name']:[d['byName'][0] for d in t['dependencies']] for t in package['targets'] if t['type']=='regular' and t['name']!=TEST_SUPPORT}
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
# TH3: nothing but a test target may depend on TestSupport or import it, and it depends on nothing. TH5: and it is in no `products:` entry.
problems=test_support_problems(package)
assert not problems, '; '.join(problems)
for base in [root/'Packages/NativeMusic/Sources', root/'App/Sources', root/'Extensions/Sources']:
 for path in base.rglob('*.swift'):
  assert not re.search(r'^\s*(@testable\s+)?import TestSupport\b',path.read_text(),re.M), f'TestSupport imported by production code: {path}'
print(f"PASS: TestSupport is a test-only library (no dependencies; only test targets use it) and in none of the {len(package.get('products', []))} products")
