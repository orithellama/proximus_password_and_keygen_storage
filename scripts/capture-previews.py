#!/usr/bin/env python3
"""Capture actual SwiftUI screens with isolated sample vault data. No real vault is opened."""
import argparse
import json
import struct
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--skip-build', action='store_true')
args = parser.parse_args()
if not args.skip_build:
    subprocess.run(['python3', 'scripts/generate-project.py'], cwd=root, check=True)
    subprocess.run(['xcodebuild', '-project', 'ProximusPasswords.xcodeproj', '-scheme', 'ProximusPasswords-macOS',
                    '-configuration', 'Debug', '-destination', 'generic/platform=macOS', '-derivedDataPath', 'build/preview',
                    'CODE_SIGNING_ALLOWED=NO', 'DEVELOPMENT_TEAM=', 'build'], cwd=root, check=True)
app = root / 'build/preview/Build/Products/Debug/Proximus.app'
output = root / 'build/launch'
output.mkdir(parents=True, exist_ok=True)
shots = []
for name, flag in [('proximus-app', None), ('proximus-wallets', '--wallet-screen'), ('proximus-wallet-balances', '--wallet-detail-screen'), ('proximus-recovery', '--recovery-screen'), ('proximus-generator', '--generator-screen')]:
    destination = output / (name + '.png')
    command = ['open', '-n', '-W', '--env', f'PROXIMUS_PREVIEW_OUTPUT={destination}', str(app), '--args', '--capture-preview', '--dark']
    if flag:
        command.append(flag)
    subprocess.run(command, cwd=root, check=True, timeout=45)
    data = destination.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Screenshot did not produce a PNG')
    width, height = struct.unpack('>II', data[16:24])
    shots.append({'filename': destination.name, 'width': width, 'height': height})
    print(f'Captured {destination.name}: {width}x{height}')
(output / 'screenshots.json').write_text(json.dumps(shots, indent=2) + '\n')
