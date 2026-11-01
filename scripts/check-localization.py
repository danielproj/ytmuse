#!/usr/bin/env python3
"""W28 (T28.4): audits Resources/Localizable.xcstrings against the specification's locale set, the manifest and the source tree.

Fails (exit 1) when:
  - the committed catalog or manifest differ from what scripts/l10n/build-catalog.py writes;
  - the catalog localizes into an identifier outside the 47 base locales and six formatting variants (L10N01), or the manifest advertises one;
  - a core key lacks a locale, a plural entry lacks a CLDR category for its language, or a translation changes its source's placeholders;
  - a brand/product name in the English source (YTMuse, YouTube Music, Google, Mac, macOS) was translated or transliterated;
  - a literal `String(localized:)` key of the sources is missing from the catalog;
  - a sentence is assembled from fragments (a localized string concatenated with `+`);
  - a non-English value is not marked as a machine seed pending review, or the manifest claims release quality (L10N05, L10N06).
`--self-test` plants each defect in a copy of the data and requires the audit to catch it.
"""
import copy, json, re, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / 'Resources'
sys.path.insert(0, str(ROOT / 'scripts/l10n'))
import importlib.util
spec = importlib.util.spec_from_file_location('build_catalog', ROOT / 'scripts/l10n/build-catalog.py')
build = importlib.util.module_from_spec(spec); spec.loader.exec_module(build)

BRANDS = ['YTMuse', 'YouTube Music', 'Google', 'Mac', 'macOS']
PLACEHOLDER = build.PLACEHOLDER

def values(entry, locale):
    """Every string a locale carries for an entry (one for a plain string, one per category for a plural), with its state."""
    loc = entry.get('localizations', {}).get(locale)
    if loc is None: return []
    if 'stringUnit' in loc: return [('', loc['stringUnit'])]
    out = []
    for category, unit in loc.get('variations', {}).get('plural', {}).items(): out.append((category, unit['stringUnit']))
    return out

def expected_complete():
    inherits = {'en-GB': 'en', 'en-US': 'en', 'fr-CH': 'fr', 'de-CH': 'de'}
    return [l for l in build.BASE + build.VARIANTS if l == 'en' or l in build.FULL or inherits.get(l) in ('en',) + tuple(build.FULL)]

def audit(catalog, manifest, sources=None):
    import source_keys as sk
    problems = []
    allowed = set(build.BASE + build.VARIANTS)
    strings = catalog['strings']
    categories = build.plural_categories()
    simple, plural = build.parse_core()
    keys = list(simple.values()) + [forms['other'] for forms in plural.values()]
    # Locale identifiers: exact set, no strays.
    used = {locale for entry in strings.values() for locale in entry.get('localizations', {})}
    for locale in sorted(used - allowed): problems.append(f'catalog localizes into {locale!r}, which is not in the specification set')
    for locale in manifest['baseLocales'] + manifest['formattingVariants']:
        if locale not in allowed: problems.append(f'manifest lists {locale!r}, which is not in the specification set')
    if manifest['baseLocales'] != build.BASE or len(build.BASE) != 47: problems.append(f'manifest base locales are not the exact 47 ({len(manifest["baseLocales"])})')
    if manifest['formattingVariants'] != build.VARIANTS: problems.append('manifest formatting variants are not the six of the specification')
    if manifest.get('releaseQualityClaim') is not False: problems.append('manifest claims release quality')
    # Per locale: the fully translated locales have EVERY translatable key; every other locale is validated for whatever it carries.
    required = set(build.FULL) | {'de-CH'}
    explicit = [l for l in build.BASE if l != 'en'] + ['de-CH', 'pt-PT']
    for locale in explicit:
        base_locale = 'pt' if locale == 'pt-PT' else 'de' if locale == 'de-CH' else locale
        for key in keys:
            entry = strings.get(key)
            if entry is None: problems.append(f'translatable key missing from catalog: {key!r}'); continue
            got = values(entry, locale)
            if not got:
                if locale in required: problems.append(f'{locale}: key without translation: {key!r}')
                continue
            is_plural = got[0][0] != ''
            if is_plural:
                need = set(categories(base_locale)); have = {c for c, _ in got}
                if have != need: problems.append(f'{locale}: plural categories {sorted(have)} != {sorted(need)} for {key!r}')
            english = values(entry, 'en')
            ref_unit = dict(english).get('other', english[0][1]) if english else None
            ref = ref_unit['value'] if ref_unit else key
            for category, unit in got:
                if build.placeholders(unit['value']) != build.placeholders(ref):
                    if not (is_plural and category in ('one', 'zero', 'two') and not PLACEHOLDER.search(unit['value'])):
                        problems.append(f'{locale}: placeholders differ from the source in {key!r} ({category or "-"})')
                if unit.get('state') != 'needs_review': problems.append(f'{locale}: {key!r} is not marked needs_review (machine seed)')
                if not unit['value'].strip(): problems.append(f'{locale}: empty value for {key!r}')
            for brand in BRANDS:
                if re.search(r'(?<![A-Za-z])' + re.escape(brand) + r'(?![A-Za-z])', key):
                    for category, unit in got:
                        text = unit['value'].replace('YouTube-Music', 'YouTube Music') if base_locale == 'de' else unit['value']   # a German hyphenated compound keeps the name's spelling
                        if brand not in text and (is_plural is False or category in ('other', 'many')):
                            problems.append(f'{locale}: brand name {brand!r} not kept verbatim in {key!r}')
    for key in keys:
        if 'MACHINE SEED' not in strings.get(key, {}).get('comment', ''): problems.append(f'translatable key lacks the machine-seed comment: {key!r}')
    # English values are the SOURCE strings: a key is its own English text unless it is listed in english-values.txt, no value in any language is an identifier
    # echoed back (`detailSeparator`), and a counted key listed in english-plurals.txt keeps its singular form.
    values_register, plurals_register = build.english_values(), build.english_plurals()
    identifier = re.compile(r'^[a-z]+[A-Z][a-z]+[A-Za-z0-9]*$')
    for key, entry in strings.items():
        en = entry.get('localizations', {}).get('en')
        if en and 'stringUnit' in en:
            expected = values_register.get(key, key)
            if en['stringUnit']['value'] != expected: problems.append(f'English value of {key!r} is {en["stringUnit"]["value"]!r}, not the source string {expected!r}')
        for locale, loc in entry.get('localizations', {}).items():
            for _, unit in values(entry, locale):
                if identifier.match(unit['value']) and unit['value'] == key: problems.append(f'{locale}: the value of {key!r} is the identifier itself')
    for key, one in plurals_register.items():
        en = strings.get(key, {}).get('localizations', {}).get('en', {})
        forms = ((en.get('variations') or {}).get('plural')) or {}
        if forms.get('one', {}).get('stringUnit', {}).get('value') != one or forms.get('other', {}).get('stringUnit', {}).get('value') != key:
            problems.append(f'English singular form of {key!r} was dropped (expected {one!r})')
    for key in values_register:
        if key not in strings: problems.append(f'english-values.txt names a key that is not in the catalog: {key!r}')
    # Manifest agrees with the catalog and says what is complete.
    if manifest['completeLocales'] != expected_complete(): problems.append(f'manifest completeLocales {manifest["completeLocales"]} != {expected_complete()}')
    if set(manifest['completeLocales']) | set(manifest['partialLocales']) != allowed or set(manifest['completeLocales']) & set(manifest['partialLocales']): problems.append('manifest complete/partial locales do not partition the set')
    if manifest['catalogKeyCount'] != len(strings): problems.append(f'manifest key count {manifest["catalogKeyCount"]} != catalog {len(strings)}')
    if manifest['translatableKeyCount'] != len(keys): problems.append('manifest translatableKeyCount differs from core-en.txt')
    for locale, entry in manifest['locales'].items():
        if entry['complete'] != (locale in manifest['completeLocales']): problems.append(f'{locale}: complete flag disagrees with completeLocales')
        if not entry['complete'] and entry['coverage'] >= 1: problems.append(f'{locale}: partial locale claims full coverage')
    # SwiftUI and String(localized:) literals of the sources must be keys of the catalog (QA-only strings excepted); no sentence built from fragments.
    if sources is None:
        sources = []
        for base in (ROOT / 'Packages/NativeMusic/Sources', ROOT / 'App/Sources', ROOT / 'Extensions/Sources'):
            if base.exists(): sources += [(str(p.relative_to(ROOT)), p.read_text()) for p in sorted(base.rglob('*.swift')) if not any(x in p.name for x in sk.EXCLUDE_FILES)]
    present = sk.catalog_matcher(set(strings))
    for key, where in sk.source_keys_in(sources).items():
        if len(re.findall(r'[A-Za-z]', key)) < 2 or sk.is_qa(key) or '\\(' in key: continue
        if not present(key): problems.append(f'{where}: source key missing from catalog: {key!r}')
    fragments = []
    for name, text in sources:
        for line_number, line in enumerate(text.splitlines(), 1):
            code = line.split('//')[0]
            if not (re.search(r'String\(localized:[^)]*\)\s*\+', code) or re.search(r'\+\s*String\(localized:', code)): continue
            for literal in build.LITERAL.finditer(code):
                body = literal.group(1)
                if not (re.match(r'[A-Z0-9\u201c\u2018\\(]', body) and re.search(r'[.!?\u2026:\u201d]\s*$', body)): fragments.append(f'{name}:{line_number} ({body[:40]!r})')
    for where in fragments: problems.append(f'sentence assembled from fragments at {where}')
    return problems

def self_test(catalog, manifest):
    base = audit(catalog, manifest)
    assert base == [], f'baseline audit not clean: {base[:3]}'
    cases = []
    def plant(name, fn, expect, sources=None):
        c, m = copy.deepcopy(catalog), copy.deepcopy(manifest)
        fn(c, m)
        found = audit(c, m, sources=[] if sources is None else sources) if sources is not None else audit(c, m)
        cases.append((name, expect, any(expect in p for p in found)))
    key = 'Play %@'
    plant('stray locale', lambda c, m: c['strings'][key]['localizations'].__setitem__('xx', c['strings'][key]['localizations']['de']), 'not in the specification set')
    plant('missing translation (a fully translated locale)', lambda c, m: c['strings']['Home']['localizations'].pop('ru'), 'key without translation')
    plant('placeholder dropped', lambda c, m: c['strings'][key]['localizations']['de']['stringUnit'].__setitem__('value', 'Wiedergeben'), 'placeholders differ')
    plant('plural category missing', lambda c, m: c['strings']['%lld minutes']['localizations']['ru']['variations']['plural'].pop('few'), 'plural categories')
    plant('brand translated', lambda c, m: c['strings']['Welcome to YTMuse']['localizations']['fr']['stringUnit'].__setitem__('value', 'Bienvenue dans MusiqueTube'), 'brand name')
    plant('release claim', lambda c, m: m.__setitem__('releaseQualityClaim', True), 'claims release quality')
    plant('state not review', lambda c, m: c['strings']['Home']['localizations']['de']['stringUnit'].__setitem__('state', 'translated'), 'not marked needs_review')
    plant('an identifier echoed as the English value (N1)', lambda c, m: c['strings']['detailSeparator']['localizations']['en']['stringUnit'].__setitem__('value', 'detailSeparator'), 'not the source string')
    plant('an identifier echoed in a translation (N1)', lambda c, m: c['strings']['detailSeparator']['localizations']['de']['stringUnit'].__setitem__('value', 'detailSeparator'), 'the identifier itself')
    plant('a dropped English singular (N1)', lambda c, m: c['strings']['%lld seconds remaining']['localizations'].__setitem__('en', {'stringUnit': {'state': 'translated', 'value': '%lld seconds remaining'}}), 'singular form')
    plant('a user key containing Diagnostic is not excluded (N2)', lambda c, m: None, 'source key missing from catalog', sources=[('Planted.swift', 'Text("Diagnostic reports are never sent anywhere.")')])
    plant('manifest overclaims a locale', lambda c, m: m['completeLocales'].append('mt'), 'completeLocales')
    plant('a SwiftUI Text key missing from the catalog', lambda c, m: None, 'source key missing from catalog', sources=[('Planted.swift', 'Text("A sentence nobody added to the catalog")')])
    plant('a Button key missing from the catalog', lambda c, m: None, 'source key missing from catalog', sources=[('Planted.swift', 'Button("Planted button label") { }')])
    for name, expect, caught in cases: print(f'  self-test {"caught" if caught else "MISSED"}: {name}')
    assert all(c for _, _, c in cases), 'a planted defect was not caught'
    # Control: an audit that never fails would pass the planted cases above only by accident; the clean baseline is the control.
    print(f'self-test: {len(cases)} planted defects caught; clean baseline passes')

def main():
    catalog = json.loads((RES / 'Localizable.xcstrings').read_text())
    manifest = json.loads((RES / 'LocalizationManifest.json').read_text())
    if '--self-test' in sys.argv: self_test(catalog, manifest); return 0
    status = subprocess.run([sys.executable, str(ROOT / 'scripts/l10n/build-catalog.py'), '--check']).returncode
    problems = audit(catalog, manifest)
    if status != 0: problems.append('catalog/manifest differ from build-catalog.py output')
    for p in problems[:60]: print('FAIL:', p, file=sys.stderr)
    if problems: print(f'{len(problems)} localization problem(s)', file=sys.stderr); return 1
    total = len(catalog['strings'])
    print(f'localization audit ok: {len(manifest["baseLocales"])} base locales + {len(manifest["formattingVariants"])} variants, {manifest["translatableKeyCount"]} translatable keys, complete: {", ".join(manifest["completeLocales"])}; {len(manifest["partialLocales"])} locales partial (English fallback); {total} catalog keys; release quality NOT claimed')
    return 0
if __name__ == '__main__': sys.exit(main())
