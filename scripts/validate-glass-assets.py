#!/usr/bin/env python3
"""Check provenance and layered foreground integrity without modifying generated artwork."""
import base64
import hashlib
import json
from pathlib import Path
import re
import struct

root = Path(__file__).resolve().parents[1]
checked = 0
for directory in [root / 'Resources/Brand', root / 'Resources/Brand/Glass-v2']:
    hashes = json.loads((directory / 'asset-manifest.json').read_text())['sha256']
    assert hashes, 'Empty provenance manifest'
    for name, expected in hashes.items():
        assert hashlib.sha256((directory / name).read_bytes()).hexdigest() == expected, name
        checked += 1
brand = root / 'Resources/Brand/Glass-v2'
source = brand / 'YTMuse.icon'
original = (brand / 'YTMuse-Glass-Foreground-v2.png').read_bytes()
assert (source / 'Assets/Musical-M.png').read_bytes() == original
svg = (source / 'Assets/Musical-M.svg').read_text()
embedded = re.search(r'data:image/png;base64,([A-Za-z0-9+/=]+)', svg)
assert embedded and base64.b64decode(embedded[1]) == original
assert 'x="112" y="112" width="800" height="800"' in svg
icon = json.loads((source / 'icon.json').read_text())
assert icon['supported-platforms']['squares'] == ['macOS']
assert icon['fill'] and len(icon['groups']) == 1
assert icon['groups'][0]['layers'][0]['image-name'] == 'Musical-M.svg'
assert icon['groups'][0]['layers'][0]['glass'] is True
sizes = []
for path in sorted((brand / 'YTMuseGlass.iconset').glob('*.png')):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack('>II', data[16:24])
    expected = int(re.search(r'icon_(\d+)x', path.name)[1]) * (2 if '@2x' in path.name else 1)
    assert width == height == expected
    sizes.append(width)
assert len(sizes) == 10 and min(sizes) == 16 and max(sizes) == 1024
print(json.dumps({'status': 'pass', 'originalHashChecks': checked, 'nativeCompatibilitySizes': sizes,
                  'originalForegroundPreserved': True, 'layeredSource': str(source.relative_to(root))}, indent=2))
