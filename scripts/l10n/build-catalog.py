#!/usr/bin/env python3
"""W28: builds the localized part of Resources/Localizable.xcstrings and Resources/LocalizationManifest.json from
Resources/L10N/core-en.txt (the English core set) and Resources/L10N/seeds/<locale>.txt (machine seeds, one file per locale).

Every non-English value this writes is a MACHINE SEED pending human review (W42). The catalog marks each core string with a comment saying so
and every non-English value with state `needs_review`; the manifest says `releaseQualityClaim: false`. The script is idempotent and refuses
(exit 1) when a seed misses a core id, changes the placeholders of its English source, or lacks a plural category the language needs.

Usage: build-catalog.py [--check]   (--check verifies the committed catalog and manifest are what a build would write; it writes nothing)
"""
import json, re, sys, unicodedata
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / 'Resources'
EU = "bg hr cs da nl en et fi fr de el hu ga it lv lt mt pl pt ro sk sl es sv".split()
ADDITIONAL = "ru uk be nb nn is sq bs mk sr sr-Latn tr ca eu gl cy gd rm lb ka hy az fo".split()
BASE = EU + ADDITIONAL
VARIANTS = ["en-GB", "en-US", "fr-CH", "de-CH", "it-CH", "pt-PT"]
# Locales translated for EVERY translatable key (the account holder's main languages, 2026-11-01). Every other locale is registered with its identifier,
# plural categories and formatting, carries only the first 66 seeded keys (seeds/core1) and falls back to English for the rest.
FULL = ['ru', 'de', 'es', 'fr']
COMMENT = "Core string (W28). Every non-English value is a MACHINE SEED pending human review (W42); it is not release quality."
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:l{0,2})[@d]')

def english_values():
    """key -> English value where it differs from the key (punctuation-only or identifier-style keys)."""
    out = {}
    path = RES / 'L10N/english-values.txt'
    for line in path.read_text().splitlines() if path.exists() else []:
        if line and not line.startswith('#'):
            key, value = line.split('\t', 1); out[key] = value
    return out

def english_plurals():
    """key -> English singular form of a counted key (the key is the `other` form)."""
    out = {}
    path = RES / 'L10N/english-plurals.txt'
    for line in path.read_text().splitlines() if path.exists() else []:
        if line and not line.startswith('#'):
            key, one = line.split('\t', 1); out[key] = one
    return out

def plural_categories():
    table = json.loads((RES / 'L10N/plural-categories.json').read_text())
    return lambda loc: table.get(loc, table['default'])

def parse_core():
    simple, plural = {}, {}
    for line in (RES / 'L10N/core-en.txt').read_text().splitlines():
        if not line.strip(): continue
        ident, text = line.split('|', 1)
        if ident.startswith('P'): plural[ident] = dict(part.split(':', 1) for part in text.split('\t'))
        elif ident.startswith('Q'): plural[ident] = {'other': text}   # an English key with a count: the translation supplies every CLDR category
        else: simple[ident] = text
    return simple, plural

def placeholders(text): return sorted(re.sub(r'%\d+\$', '%', p) for p in PLACEHOLDER.findall(text.replace('%%', '')))

def seed_text(locale):
    """A locale's seed: the first 66 keys (seeds/core1) and the rework 1 additions (seeds/<locale>.txt, <locale>.2.txt …), one `id|text` line each."""
    parts = [RES / 'L10N/seeds/core1' / f'{locale}.txt', RES / 'L10N/seeds' / f'{locale}.txt'] + sorted((RES / 'L10N/seeds').glob(f'{locale}.[0-9].txt'))
    return '\n'.join(p.read_text() for p in parts if p.exists())

def parse_seed(text, simple, plural, categories, locale):
    values, forms = {}, {}
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip(): continue
        ident, text = line.split('|', 1)
        if ident[0] in 'PQ': forms[ident] = dict(part.split(':', 1) for part in text.split('\t'))
        else: values[ident] = text
    problems = []
    full = locale in FULL
    for ident, english in simple.items():
        if ident not in values:
            if full: problems.append(f'{locale}: missing {ident}')
            continue
        if placeholders(values[ident]) != placeholders(english): problems.append(f'{locale}: {ident} placeholders {placeholders(values[ident])} != {placeholders(english)}')
        if not values[ident].strip(): problems.append(f'{locale}: {ident} empty')
    for ident, english in plural.items():
        got = forms.get(ident)
        if got is None:
            if full: problems.append(f'{locale}: missing {ident}')
            continue
        need = categories(locale)
        if set(got) != set(need): problems.append(f'{locale}: {ident} categories {sorted(got)} != {sorted(need)}')
        for category, text in got.items():
            if not text.strip(): problems.append(f'{locale}: {ident}.{category} empty')
            # the count placeholder must survive in every form that is used for more than "one"
            if placeholders(text) != placeholders(english['other']) and not (category in ('one', 'zero', 'two') and not PLACEHOLDER.search(text)):
                problems.append(f'{locale}: {ident}.{category} placeholders {placeholders(text)} != {placeholders(english["other"])}')
    extra = (set(values) - set(simple)) | (set(forms) - set(plural))
    if extra: problems.append(f'{locale}: unknown ids {sorted(extra)}')
    return values, forms, problems

LITERAL = re.compile(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"')
def source_keys():
    """Literal (non-interpolated) keys of every `String(localized: "…")` in the app's sources. These are not extracted by a package build, so the
    catalog needs them added here; interpolated keys are listed by check-localization.py and must be added to the core set or the catalog by hand."""
    found = set()
    for base in (ROOT / 'Packages/NativeMusic/Sources', ROOT / 'App/Sources', ROOT / 'Extensions/Sources'):
        if not base.exists(): continue
        for path in base.rglob('*.swift'):
            for match in LITERAL.finditer(path.read_text()):
                text = match.group(1)
                if '\\(' in text: continue
                found.add(text.replace('\\"', '"'))
    return found

def unit(value, state): return {"stringUnit": {"state": state, "value": value}}

def build():
    simple, plural = parse_core()
    categories = plural_categories()
    catalog = json.loads((RES / 'Localizable.xcstrings').read_text())
    strings = catalog['strings']
    # Interpolated source keys (English only; their translations are outside the core set): one key per line.
    extra = (RES / 'L10N/extra-keys.txt')
    for text in sorted(source_keys() | set(extra.read_text().splitlines() if extra.exists() else [])):
        strings.setdefault(text, {}).setdefault('localizations', {}).setdefault('en', unit(text, 'translated'))
    # English source entries for every core key (a few are new in W28: announcements, language settings).
    values, ones = english_values(), english_plurals()
    for ident, text in simple.items():
        entry = strings.setdefault(text, {})
        entry.setdefault('localizations', {})['en'] = unit(values.get(text, text), 'translated')
    for ident, forms in plural.items():
        key = forms['other']
        entry = strings.setdefault(key, {})
        if ident.startswith('P') or key in ones:
            entry.setdefault('localizations', {})['en'] = {"variations": {"plural": {c: unit(t, 'translated') for c, t in ({**forms, 'one': ones[key], 'other': key} if key in ones else forms).items()}}}
        else:
            entry.setdefault('localizations', {})['en'] = unit(key, 'translated')
    # Deterministic: every non-English localization comes from the seeds, none survives from an earlier catalog.
    for entry in strings.values():
        if 'localizations' in entry: entry['localizations'] = {k: v for k, v in entry['localizations'].items() if k == 'en'}
    problems, seeds = [], {}
    for locale in BASE:
        if locale == 'en': continue
        text = seed_text(locale)
        if not text.strip(): problems.append(f'{locale}: no seed file'); continue
        values, forms, p = parse_seed(text, simple, plural, categories, locale)
        problems += p; seeds[locale] = (values, forms)
    if problems: return None, None, problems
    # Variants: pt-PT is the Portuguese seed (the EU language is Portuguese of Portugal); de-CH drops the sharp s (Swiss orthography).
    seeds['pt-PT'] = seeds['pt']
    de_values, de_forms = seeds['de']
    seeds['de-CH'] = ({k: v.replace('ß', 'ss') for k, v in de_values.items()}, {k: {c: t.replace('ß', 'ss') for c, t in f.items()} for k, f in de_forms.items()})
    for locale, (values, forms) in seeds.items():
        for ident, text in simple.items():
            if ident in values: strings[text].setdefault('localizations', {})[locale] = unit(values[ident], 'needs_review')
        for ident, english in plural.items():
            if ident in forms: strings[english['other']].setdefault('localizations', {})[locale] = {"variations": {"plural": {c: unit(t, 'needs_review') for c, t in forms[ident].items()}}}
    for text in list(simple.values()) + [f['other'] for f in plural.values()]:
        strings[text]['comment'] = COMMENT
    for entry in strings.values():
        if 'localizations' in entry: entry['localizations'] = dict(sorted(entry['localizations'].items()))
    catalog['strings'] = dict(sorted(strings.items()))
    total = len(strings)
    translatable = len(simple) + len(plural)
    def has(locale, text): return locale in strings[text].get('localizations', {})
    def count(locale): return sum(1 for t in simple.values() if has(locale, t)) + sum(1 for f in plural.values() if has(locale, f['other']))
    inherits_map = {'en-GB': 'en', 'en-US': 'en', 'fr-CH': 'fr', 'de-CH': 'de', 'it-CH': 'it', 'pt-PT': 'pt'}
    locales = {}
    for locale in BASE + VARIANTS:
        kind = 'source' if locale == 'en' else ('formatting-variant' if locale in VARIANTS else 'base')
        entry = {"kind": kind, "plural_categories": categories(locale if locale != 'pt-PT' else 'pt')}
        if locale in ('en-GB', 'en-US', 'fr-CH', 'it-CH'):
            base_locale = inherits_map[locale]
            entry.update({"inheritsStringsFrom": base_locale, "translatedKeys": 0, "origin": f"inherits {base_locale}", "review": "inherits-base",
                          "complete": base_locale == 'en' or count(base_locale) == translatable})
            entry["coverage"] = 1.0 if entry["complete"] else round(count(base_locale) / translatable, 4)
        else:
            translated = translatable if locale == 'en' else count(locale)
            entry.update({"translatedKeys": translated, "coverage": round(translated / translatable, 4), "complete": translated == translatable,
                          "origin": "source" if locale == 'en' else "machine-seed", "review": "not-applicable" if locale == 'en' else "pending-W42"})
            if locale in inherits_map: entry["derivedFrom"] = inherits_map[locale]
        locales[locale] = entry
    manifest = {
        "sourceLanguage": "en",
        "scope": "every translatable catalog key",
        "scopeNote": "'complete' means every translatable key (all of Resources/L10N/core-en.txt: every catalog key except the QA-only and non-linguistic ones listed in excluded-keys.txt) has a value, with its plural categories. The other locales are registered with their exact identifier, plural categories and formatting, carry only the first seeded keys, and fall back to English for the rest; 'coverage' states how much.",
        "releaseQualityClaim": False,
        "reviewStatus": "Non-English values are machine seeds. Human translation review is W42; until then no locale is advertised as reviewed.",
        "baseLocales": BASE, "formattingVariants": VARIANTS,
        "catalogKeyCount": total, "translatableKeyCount": translatable,
        "completeLocales": [l for l in BASE + VARIANTS if locales[l]["complete"]],
        "partialLocales": [l for l in BASE + VARIANTS if not locales[l]["complete"]],
        "locales": locales,
    }
    return catalog, manifest, []

def main():
    check = '--check' in sys.argv
    catalog, manifest, problems = build()
    if problems:
        print('\n'.join(problems), file=sys.stderr); return 1
    new_catalog = json.dumps(catalog, indent=2, ensure_ascii=False) + "\n"
    new_manifest = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    if check:
        ok = (RES / 'Localizable.xcstrings').read_text() == new_catalog and (RES / 'LocalizationManifest.json').read_text() == new_manifest
        print('catalog and manifest are current' if ok else 'catalog or manifest differ from what build-catalog.py writes', file=sys.stderr if not ok else sys.stdout)
        return 0 if ok else 1
    (RES / 'Localizable.xcstrings').write_text(new_catalog)
    (RES / 'LocalizationManifest.json').write_text(new_manifest)
    print(f'wrote catalog ({manifest["catalogKeyCount"]} keys) and manifest ({len(manifest["completeLocales"])} complete locales: {', '.join(manifest["completeLocales"])})')
    return 0
if __name__ == '__main__': sys.exit(main())
