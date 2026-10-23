#!/usr/bin/env python3
"""Render the release text maintained in README into an upload-ready file."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
readme = (root / 'README.md').read_text()
notes = readme.split('<!-- release-notes:start -->', 1)[1].split('<!-- release-notes:end -->', 1)[0].strip()
assert f'Proximus {version}' in notes, 'Release text must match VERSION'
output = root / 'dist' / f'Proximus-{version}-release-notes.txt'
output.parent.mkdir(exist_ok=True)
output.write_text(notes + '\n')
print(output)
