#!/usr/bin/env python3
"""Fail closed when a container view carries an accessibilityIdentifier without being its own accessibility container.

SwiftUI hands a container's identifier to every element inside it unless the container is made an element of its own,
so a child's identifier is replaced and a UI test (or any tool keyed on identifiers) can no longer find the child. UI1 found
two such screens (Downloads' aggregate line, Recap's entries). The rule: in a modifier chain whose root is a stack, group,
form, grid or a pass-through wrapper (MusicGlassGroup, GlassEffectContainer, TransportBar, SectionShelf), an
`.accessibilityElement(children: .contain)` (or `.combine`) must appear BEFORE `.accessibilityIdentifier(...)`.
A bare `.accessibilityElement()` or `children: .ignore` is not a fix when the chain's own content carries an identifier: it
swallows the identified children instead of exposing them.

Roots that are properties or functions (`card.accessibilityIdentifier(...)`) are resolved through their declaration when
it is in the same file (`var card: some View { ... }` / `func card(...) -> some View { ... }`): when the declaration's body
contains a container root they are checked like a container. A root with no computed declaration in the file (a parameter, a stored
closure) cannot be resolved and is listed with --list-unresolved only.

ScrollView, List and ScrollViewReader are exempt: they are native accessibility containers (the T10/T11/T12 suites find rows by
identifier inside `catalogScroll`, `destinationScroll`, `libraryList`), so their identifier names the scroll area and does not
replace its children's.

Usage: check-accessibility-containers.py [--self-test] [--list-unresolved] [paths...]
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DIRS = [ROOT / 'Packages/NativeMusic/Sources', ROOT / 'App']
CONTAINERS = {'VStack', 'HStack', 'ZStack', 'Group', 'LazyVStack', 'LazyHStack', 'LazyVGrid', 'LazyHGrid', 'Grid', 'GridRow',
              'ForEach', 'Form', 'Section', 'GroupBox', 'DisclosureGroup', 'ControlGroup', 'TabView', 'NavigationStack',
              'NavigationSplitView', 'HSplitView', 'VSplitView', 'Table', 'ViewThatFits', 'AnyLayout', 'SectionShelf',
              'MusicGlassGroup', 'GlassEffectContainer', 'TransportBar'}
# Containers that are deliberately one leaf element: the identifier is meant to reach the single control or text inside, and
# a test queries them by that element's type or label. Keyed on (file name, static identifier text before any interpolation),
# exactly; every entry needs a reason.
LEAF_IDENTIFIERS = {
    ('BottomPlayer.swift', 'sleepRemaining'): 'a Group of alternative Texts; exactly one shows, and the test reads it as a static text',
    ('LibraryView.swift', 'libraryControl-'): 'a Group choosing between two spellings of one Button; the test reads the button\'s own label and enabled state',
    ('LyricsView.swift', 'lyricsLine-'): 'a Group choosing between a Button and a Text for one lyric line; no child carries an identifier',
    ('PlaylistCreateView.swift', 'playlistCreating'): 'a ProgressView and its caption, one status; no child carries an identifier',
    ('SearchView.swift', 'searchRemoteLoading'): 'a ProgressView and its caption, one status; no child carries an identifier',
}
CLOSERS = {')': '(', ']': '[', '}': '{'}
OPENERS = {'(': ')', '[': ']', '{': '}'}

def strip(text):
    """Blank out comments and string contents (keeping length and newlines) so brackets inside them do not count."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith('//', i):
            j = text.find('\n', i); j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2); j = n if j < 0 else j + 2
            out.append(re.sub(r'[^\n]', ' ', text[i:j])); i = j
        elif c == '"':
            if text.startswith('"""', i):
                j = text.find('"""', i + 3); j = n if j < 0 else j + 3
                out.append('"' + re.sub(r'[^\n]', ' ', text[i + 1:j - 1]) + '"' if j - i >= 2 else text[i:j]); i = j
                continue
            j = i + 1
            while j < n and text[j] != '"' and text[j] != '\n':
                if text[j] == '\\': j += 1
                j += 1
            out.append('"' + ' ' * (j - i - 1) + '"'); i = j + 1
        else:
            out.append(c); i += 1
    return ''.join(out)

def back_over_group(s, i):
    """s[i] is a closer; return the index of its opener."""
    stack = [s[i]]; i -= 1
    while i >= 0 and stack:
        c = s[i]
        if c in CLOSERS: stack.append(c)
        elif c in '([{':
            if CLOSERS[stack[-1]] == c: stack.pop()
        i -= 1
    return i + 1

def forward_group(s, i):
    """s[i] is an opener; return the index just past its closer."""
    stack = [OPENERS[s[i]]]; i += 1
    while i < len(s) and stack:
        c = s[i]
        if c in OPENERS: stack.append(OPENERS[c])
        elif c in CLOSERS and stack[-1] == c: stack.pop()
        i += 1
    return i

def chain_before(s, dot):
    """The modifier chain ending at the `.` at index `dot`: returns (root, [(name, index)...]) walking backwards."""
    names, i = [], dot - 1
    while True:
        while i >= 0 and s[i].isspace(): i -= 1
        if i >= 0 and s[i] in CLOSERS:
            i = back_over_group(s, i) - 1
            while i >= 0 and s[i].isspace(): i -= 1
            # `Name { ... }` (trailing closure) or `Name(...)`: the callee name sits before the group. A labelled trailing
            # closure (`Button { } label: { }`, `.x(for:) { } action: { }`) puts `label:` between two groups.
            if i >= 0 and s[i] == ':':
                k = i - 1
                while k >= 0 and (s[k].isalnum() or s[k] == '_'): k -= 1
                k2 = k
                while k2 >= 0 and s[k2].isspace(): k2 -= 1
                if k < i - 1 and k2 >= 0 and s[k2] in CLOSERS: i = k2
            if i >= 0 and s[i] in CLOSERS:
                continue
        if i >= 0 and s[i] == '?': i -= 1
        end = i + 1
        while i >= 0 and (s[i].isalnum() or s[i] == '_'): i -= 1
        name = s[i + 1:end]
        if not name: return None, names
        names.append((name, i + 1))
        j = i
        while j >= 0 and s[j].isspace(): j -= 1
        if j >= 0 and s[j] == '.':
            i = j - 1
            continue
        return name, names

def declaration_body(s, name):
    """The body of a computed property or function called `name` declared in this file, or None."""
    for m in re.finditer(r'\b(?:var|func)\s+' + re.escape(name) + r'\b', s):
        j = m.end()
        if s.startswith('(', s.find('(', j) if s.find('(', j) == j else -1):   # func name(...): skip its parameter list
            j = forward_group(s, j)
        line_end = s.find('\n', j); line_end = len(s) if line_end < 0 else line_end
        k = s.find('{', j)
        # A stored property (`var x: T = ...`, `let x: T`) has no body before the next declaration; a computed one opens a brace.
        if k < 0 or ('=' in s[j:k] and 'some' not in s[j:k]): continue
        if s.find('\n', j) != -1 and k > line_end and not re.match(r'[^\n]*\bsome\b|\s*->', s[j:line_end]): continue
        return s[k:forward_group(s, k)]
    return None

def element_fixes(s, names, content_identified):
    """Whether an accessibilityElement before the identifier actually exposes the children."""
    for name, index in names[:-1]:
        if name == 'accessibilityRepresentation': return True
        if name != 'accessibilityElement': continue
        j = index + len(name)
        arguments = s[j:forward_group(s, j)] if j < len(s) and s[j] == '(' else '()'
        if '.contain' in arguments or '.combine' in arguments: return True
        # bare `.accessibilityElement()` is `.ignore`: it removes the children, so it only "fixes" a container with none to expose.
        if not content_identified: return True
    return False

def findings(text, label):
    s = strip(text)
    out, unresolved = [], []
    base = label.rsplit('/', 1)[-1]
    for m in re.finditer(r'\.accessibilityIdentifier\(', s):
        root, names = chain_before(s, m.start())
        line = s.count('\n', 0, m.start()) + 1
        if root is None: continue
        literal = re.match(r'\.accessibilityIdentifier\(\s*"([^"\\]*)', text[m.start():])
        identifier = literal.group(1) if literal else ''
        chain_text = s[names[-1][1]:m.start()]
        content_identified = 'accessibilityIdentifier' in chain_text
        container = root in CONTAINERS
        if not container and root[:1].islower() and root != 'self':
            body = declaration_body(s, root)
            if body is None: unresolved.append((label, line, root)); continue
            container = any(re.search(r'\b' + c + r'\s*[({]', body) for c in CONTAINERS)
            content_identified = content_identified or 'accessibilityIdentifier' in body
        if container and not element_fixes(s, names, content_identified) and (base, identifier) not in LEAF_IDENTIFIERS:
            out.append((label, line, root))
    return out, unresolved

def scan(paths):
    bad, unresolved = [], []
    for base in paths:
        for p in sorted(Path(base).rglob('*.swift')) if Path(base).is_dir() else [Path(base)]:
            b, u = findings(p.read_text(), str(p.relative_to(ROOT)) if p.is_absolute() and ROOT in p.parents else str(p))
            bad += b; unresolved += u
    return bad, unresolved

PLANTED = '''
import SwiftUI
struct Planted: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("child").accessibilityIdentifier("child")
        }.accessibilityIdentifier("container")
    }
}
'''
FIXED = PLANTED.replace('}.accessibilityIdentifier("container")', '}.accessibilityElement(children: .contain).accessibilityIdentifier("container")')
REFORMATTED = PLANTED.replace('}.accessibilityIdentifier("container")', '''}
            // keep the children reachable
            .padding(0)
            .accessibilityElement(
                children: .contain
            )
            .padding(1)
            .accessibilityIdentifier("container")''')
IDENTIFIER_FIRST = PLANTED.replace('}.accessibilityIdentifier("container")', '}.accessibilityIdentifier("container").accessibilityElement(children: .contain)')
BARE_ELEMENT = PLANTED.replace('}.accessibilityIdentifier("container")', '}.accessibilityElement().accessibilityIdentifier("container")')
IGNORE_ELEMENT = PLANTED.replace('}.accessibilityIdentifier("container")', '}.accessibilityElement(children: .ignore).accessibilityIdentifier("container")')
PROPERTY_ROOT = '''
struct PlantedProperty: View {
    private var card: some View {
        VStack { Text("child").accessibilityIdentifier("child") }
    }
    var body: some View { card.accessibilityIdentifier("card") }
}
'''
PROPERTY_ROOT_FIXED = PROPERTY_ROOT.replace('card.accessibilityIdentifier("card")', 'card.accessibilityElement(children: .contain).accessibilityIdentifier("card")')
FUNCTION_ROOT = PROPERTY_ROOT.replace('private var card: some View {', 'private func card(_ n: Int) -> some View {').replace('card.accessibilityIdentifier', 'card(1).accessibilityIdentifier')
GLASS_WRAPPER = '''
struct PlantedGlass: View {
    var body: some View {
        MusicGlassGroup { HStack { Button("a") {}.accessibilityIdentifier("a") } }.accessibilityIdentifier("bar")
    }
}
'''
GLASS_CONTAINER = GLASS_WRAPPER.replace('MusicGlassGroup', 'GlassEffectContainer')

def self_test():
    caught = lambda text, label='x.swift': bool(findings(text, label)[0])
    assert caught(PLANTED), 'a container with an identifier and no accessibilityElement must be reported'
    assert not caught(FIXED), 'the .contain form must pass'
    assert not caught(REFORMATTED), 'a harmless reformat (comment, split lines, modifiers between) must survive'
    assert not caught(PLANTED.replace('VStack(alignment: .leading, spacing: 6)', 'HStack').replace('}.accessibilityIdentifier("container")', '}.accessibilityElement(children: .combine).accessibilityIdentifier("container")'))
    assert not caught('Text("a // b {").accessibilityIdentifier("x")'), 'a leaf view is not a container'
    assert caught('VStack { Text("}") }.padding().accessibilityIdentifier("x")'), 'brackets inside a string must not hide the root'
    assert caught(IDENTIFIER_FIRST), 'the identifier must come after accessibilityElement'
    assert caught(BARE_ELEMENT), 'a bare accessibilityElement() swallows identified children, it does not expose them'
    assert caught(IGNORE_ELEMENT), 'children: .ignore swallows identified children'
    assert not caught(BARE_ELEMENT.replace('Text("child").accessibilityIdentifier("child")', 'Text("child")')), 'a bare element over children with no identifiers hides nothing'
    assert caught(PROPERTY_ROOT), 'a same-file property that returns a container is a container root'
    assert caught(FUNCTION_ROOT), 'a same-file function that returns a container is a container root'
    assert not caught(PROPERTY_ROOT_FIXED), 'the property root with .contain passes'
    assert not caught('struct S: View { let surface: (Int) -> AnyView\n var body: some View { surface(1).accessibilityIdentifier("x") } }'), 'a stored closure cannot be resolved and is not flagged'
    assert caught(GLASS_WRAPPER), 'MusicGlassGroup is a pass-through container'
    assert caught(GLASS_CONTAINER), 'GlassEffectContainer is a pass-through container'
    assert not caught(GLASS_WRAPPER.replace('.accessibilityIdentifier("bar")', '.accessibilityElement(children: .contain).accessibilityIdentifier("bar")'))
    leaf = 'Group { Text("a") }.accessibilityIdentifier("sleepRemaining")'
    assert not caught(leaf, 'Sources/BottomPlayer.swift'), 'the allowlisted wrapper passes in its own file'
    assert caught(leaf, 'Sources/Elsewhere.swift'), 'the allowlist is keyed on the file'
    assert caught('Group { Text("a") }.accessibilityIdentifier("sleepRemainingFoo")', 'Sources/BottomPlayer.swift'), 'the allowlist is exact, not a prefix'
    print('check-accessibility-containers self-test: ok')

if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if '--self-test' in sys.argv:
        self_test()
        if not args: sys.exit(0)
    bad, unresolved = scan(args or DEFAULT_DIRS)
    for label, line, root in bad:
        print(f'{label}:{line}: {root} carries an accessibilityIdentifier without .accessibilityElement(children:) before it', file=sys.stderr)
    if '--list-unresolved' in sys.argv:
        for label, line, root in unresolved: print(f'unresolved {label}:{line}: {root}')
    if bad: sys.exit(1)
    print('PASS: no container view carries an accessibilityIdentifier without being its own accessibility element')
