#!/usr/bin/env python3
"""Capture actual SwiftUI screens with isolated sample vault data. No real vault is opened."""
import argparse
import json
import plistlib
import struct
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--skip-build', action='store_true')
parser.add_argument('--only', help='Capture one screen by filename stem, such as proximus-app')
parser.add_argument('--light', action='store_true', help='Capture the light appearance')
args = parser.parse_args()
if not args.skip_build:
    subprocess.run(['python3', 'scripts/generate-project.py'], cwd=root, check=True)
    subprocess.run(['xcodebuild', '-project', 'ProximusPasswords.xcodeproj', '-scheme', 'ProximusPasswords-macOS',
                    '-configuration', 'Debug', '-destination', 'generic/platform=macOS', '-derivedDataPath', 'build/preview',
                    'CODE_SIGNING_ALLOWED=NO', 'DEVELOPMENT_TEAM=', 'PROXIMUS_BUNDLE_PREFIX=org.proximus.preview', 'build'], cwd=root, check=True)
app = root / 'build/preview/Build/Products/Debug/Proximus.app'
if plistlib.loads((app / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != 'org.proximus.preview.mac':
    parser.error('Rebuild previews without --skip-build to use the isolated preview identity')
output = root / 'build/launch'
output.mkdir(parents=True, exist_ok=True)
shots = []
for name, flag in [('proximus-app', None), ('proximus-home', '--home-screen'), ('proximus-welcome', '--welcome-screen'), ('proximus-unlock', '--unlock-screen'), ('proximus-devices', '--devices-screen'), ('proximus-settings', '--settings-screen'), ('proximus-wallets', '--wallet-screen'), ('proximus-wallet-balances', '--wallet-detail-screen'), ('proximus-recovery', '--recovery-screen'), ('proximus-generator', '--generator-screen')]:
    if args.only and name != args.only:
        continue
    if args.light:
        name += '-light'
    destination = output / (name + '.png')
    destination.unlink(missing_ok=True)
    command = ['open', '-n', '-W', '-F', '--stdout', str(output / (name + '.log')), '--stderr', str(output / (name + '.log')),
               '--env', f'PROXIMUS_PREVIEW_OUTPUT={destination}', str(app), '--args', '--capture-preview']
    if not args.light:
        command.append('--dark')
    if flag:
        command.append(flag)
    subprocess.run(command, cwd=root, check=True, timeout=45)
    data = destination.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Screenshot did not produce a PNG')
    width, height = struct.unpack('>II', data[16:24])
    shots.append({'filename': destination.name, 'width': width, 'height': height})
    print(f'Captured {destination.name}: {width}x{height}', flush=True)
if not shots:
    parser.error('Unknown screen name')
if not args.only and not args.light:
    (output / 'screenshots.json').write_text(json.dumps(shots, indent=2) + '\n')
