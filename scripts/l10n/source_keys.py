"""Finds the localizable literals in the Swift sources: `String(localized: "…")` and the SwiftUI initializers that take a `LocalizedStringKey`
(Text, Button, Label, Toggle, Picker, Section, TextField, Menu, ContentUnavailableView, ProgressView, Link, confirmationDialog, alert, help,
accessibilityLabel/Hint/Value, navigationTitle, EmptyState/ErrorState/MusicBadge/VideoSurfacePlaceholder arguments …).
A literal with an interpolation is returned with the interpolation replaced by `\u0000` (a wildcard when matching the catalog).
Verbatim text (`Text(verbatim:)`, `Text(String)` from a variable) is not a key."""
import re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
STRING = r'"((?:[^"\\]|\\.)*)"'
CALLEES = r'(?:Text|Button|Label|Toggle|Picker|Section|TextField|SecureField|Menu|ContentUnavailableView|ProgressView|Link|CommandMenu|DisclosureGroup|GroupBox|LabeledContent|MusicBadge|MusicOutlineBadge|Stepper)'
PATTERNS = [
    re.compile(r'String\(localized:\s*' + STRING),
    re.compile(r'\b' + CALLEES + r'\(\s*' + STRING),
    re.compile(r'\.(?:help|accessibilityLabel|accessibilityHint|navigationTitle|confirmationDialog|alert|accessibilityValue)\(\s*(?:Text\()?' + STRING),
    re.compile(r'\b(?:EmptyState|ErrorState)\(\s*title:\s*' + STRING + r'(?:\s*,\s*message:\s*' + STRING + r')?(?:\s*,\s*recovery:\s*' + STRING + r')?'),
    re.compile(r'\b(?:message|recovery|title|detail|prompt):\s*' + STRING),
]
EXCLUDE_FILES = ('Development', 'Synthetic')   # QA-only data and fixtures
# QA-only strings (Debug readouts, test controls, development-data labels) are an EXPLICIT list of exact keys, never a substring match: a pattern once dropped
# user-facing privacy wording ("sends no diagnostics anywhere").
def qa_keys():
    path = ROOT / 'Resources/L10N/qa-keys.txt'
    return {l for l in path.read_text().splitlines() if l and not l.startswith('#')} if path.exists() else set()
QA = qa_keys()
def is_qa(key): return key in QA
def keys_in(text):
    found = set()
    for pattern in PATTERNS:
        for match in pattern.finditer(text):
            for group in match.groups():
                if group is None: continue
                if group.startswith('Text(verbatim'): continue
                if '\\(' in group and group.count('(') > group.count(')'): continue   # a literal cut at an inner quote of its own interpolation
                found.add(group)
    return found
def normalise(key):
    """Source key -> catalog key shape (interpolation -> NUL)."""
    return re.sub(r'\\\(.*?\)', '\u0000', key.replace('\\"', '"'), flags=re.S)
def source_keys_in(files):
    """`files`: iterable of (name, text)."""
    out = {}
    for name, text in files:
        for key in keys_in(text): out.setdefault(normalise(key), name)
    return out
def source_keys():
    out = {}
    for base in (ROOT / 'Packages/NativeMusic/Sources', ROOT / 'App/Sources', ROOT / 'Extensions/Sources'):
        if not base.exists(): continue
        for path in sorted(base.rglob('*.swift')):
            if any(x in path.name for x in EXCLUDE_FILES): continue
            for key in keys_in(path.read_text()):
                out.setdefault(normalise(key), str(path.relative_to(ROOT)))
    return out
def catalog_matcher(catalog_keys):
    exact = set(catalog_keys)
    patterns = [re.compile('^' + re.escape(k).replace('%@', '\\x00').replace('%lld', '\\x00').replace('%1\\$@', '\\x00').replace('%2\\$@', '\\x00').replace('\\x00', '.*') + '$', re.S) for k in catalog_keys if '%' in k]
    def present(key):
        if key in exact: return True
        probe = key.replace('\u0000', 'X')
        return any(p.match(probe) for p in patterns) if '\u0000' in key else False
    return present
