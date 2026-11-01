#!/usr/bin/env python3
"""W28: writes one review packet per locale for the human translation review (W42): every seeded key with the English source, the machine seed, the placeholders to
keep and a category (authentication, error, privacy, destructive confirmation, navigation…). Packets say, at the top, that the text is a machine seed, not release quality,
and say how much of the catalog the locale carries (the rest falls back to English).

Usage: review-packets.py OUTPUT_DIR
"""
import json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / 'Resources'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import importlib.util
spec = importlib.util.spec_from_file_location('build_catalog', Path(__file__).resolve().parent / 'build-catalog.py')
build = importlib.util.module_from_spec(spec); spec.loader.exec_module(build)
FIXED = {**{i: 'navigation and transport' for i in range(1, 13)}, **{i: 'common actions and states' for i in range(13, 28)},
         **{i: 'authentication' for i in list(range(28, 38)) + [49, 50, 51, 52]}, **{i: 'error' for i in range(38, 46)}, **{i: 'privacy' for i in (46, 47, 48)},
         **{i: 'status and announcements' for i in range(53, 59)}, **{i: 'language and region settings' for i in range(59, 64)}}
for _line in (RES / 'L10N/core-categories.txt').read_text().splitlines():
    _i, _c = _line.split('|'); FIXED[int(_i)] = _c
def category(ident, text):
    if ident.isdigit() and int(ident) in FIXED: return FIXED[int(ident)]
    if re.search(r"^(Delete|Remove|Clear|Disconnect|Stop|Reset)|Remove .* from|Reset all|This deletes|Deletes ", text): return 'destructive confirmation'
    if re.search(r"private|never sent|stays? on this|password|credential|Keychain|permission|history|saved copy", text, re.I): return 'privacy'
    if re.search(r"google|sign[- ]in|sign in|session|account|authoriz|signed", text, re.I): return 'authentication'
    if re.search(r"couldn.t|can.t|isn.t|wasn.t|didn.t|failed|offline|unavailable|try again|nothing was", text, re.I): return 'error'
    return 'interface'
def main():
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((RES / 'LocalizationManifest.json').read_text())
    simple, plural = build.parse_core()
    index = ['# W28 translation review packets', '', 'Every non-English value below is a **machine seed pending human review (W42)**. None is a release-quality claim, and the manifest says so (`releaseQualityClaim: false`). **Complete** locales carry every translatable key; the others carry only their first seeded keys and fall back to English for the rest.', '',
             '| Locale | Kind | Keys carried | Coverage | Review state |', '| - | - | - | - | - |']
    for locale in manifest['baseLocales'] + manifest['formattingVariants']:
        entry = manifest['locales'][locale]
        if locale == 'en': continue
        values, forms = {}, {}
        text = build.seed_text(locale) if locale not in ('de-CH', 'fr-CH', 'it-CH', 'en-GB', 'en-US') else ''
        if locale == 'pt-PT': text = build.seed_text('pt')
        for line in text.splitlines():
            if not line.strip(): continue
            ident, body = line.split('|', 1)
            (forms if ident[0] in 'PQ' else values)[ident] = body
        lines = [f'# {locale} — review packet', '', f'Kind: {entry["kind"]}. Origin: {entry["origin"]}. State: **{entry["review"]}**. Machine seed, not release quality (W42 reviews it). Coverage: {entry["coverage"]:.1%} of {manifest["translatableKeyCount"]} translatable keys{" (complete)" if entry["complete"] else " (the rest falls back to English)"}.', '']
        if locale == 'de-CH':
            lines += ['Derived from `de` with the Swiss spelling (sharp s written ss): review the German packet, and here only the Swiss orthography, dates, numbers and currency.']
        elif not values and not forms:
            base = entry.get('inheritsStringsFrom', '?')
            lines += [f'This variant shares the strings of `{base}`; review that packet. Review here the **formatting** only (dates, numbers, currency, plural categories: `{", ".join(entry["plural_categories"])}`).']
        else:
            lines += ['| Id | Category | English | Machine seed | Check |', '| - | - | - | - | - |']
            for ident, english in simple.items():
                if ident not in values: continue
                note = 'keep placeholders' if '%' in english else ('keep product names' if any(n in english for n in ('YTMuse', 'YouTube Music', 'Google', 'Mac')) else '')
                lines.append(f'| {ident} | {category(ident, english)} | {english.replace("|", "\\|")} | {values[ident].replace("|", "\\|")} | {note} |')
            lines += ['', '## Plurals (CLDR categories for this language: ' + ', '.join(entry['plural_categories']) + ')', '']
            for ident, english in plural.items():
                if ident in forms: lines.append(f'* {ident} — {english["other"]}: ' + ' / '.join(part.replace(':', ' = ', 1) for part in forms[ident].split('\t')))
        (out / f'{locale}.md').write_text('\n'.join(lines) + '\n')
        index.append(f'| [{locale}]({locale}.md) | {entry["kind"]} | {len(values) + len(forms)} | {entry["coverage"]:.1%} | {entry["review"]} |')
    (out / 'README.md').write_text('\n'.join(index) + '\n')
    print(f'wrote {len(manifest["baseLocales"]) + len(manifest["formattingVariants"]) - 1} packets to {out}')
main()
