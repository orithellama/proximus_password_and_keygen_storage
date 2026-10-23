#!/usr/bin/env python3
"""Create a drag-to-Applications DMG using Apple's tools, with no extra packages."""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from release_artifacts import REPOSITORY, sha256

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else None


def signature(path, team):
    run('codesign', '--verify', '--strict', '--deep', path)
    output = subprocess.run(['codesign', '--display', '--verbose=4', str(path)], capture_output=True, text=True, check=True).stderr
    if f'TeamIdentifier={team}\n' not in output:
        raise ValueError('Code signature does not match the expected Apple team')
    authority = next((line.removeprefix('Authority=') for line in output.splitlines() if line.startswith('Authority=Developer ID Application:')), None)
    if not authority:
        raise ValueError('A Developer ID Application signature is required')
    return authority


def notarize(path, profile, report):
    if not profile:
        raise ValueError('Set PROXIMUS_NOTARY_PROFILE to a notarytool Keychain profile before public packaging')
    data = run('xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile, '--wait', '--output-format', 'json', capture=True)
    report.write_bytes(data)
    if json.loads(data).get('status') != 'Accepted':
        raise ValueError(f'Apple did not accept the notarization submission. See {report}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local', action='store_true', help='Create an ad-hoc DMG for local testing, excluded from public releases')
    parser.add_argument('--app', type=Path, help='Application bundle to package')
    parser.add_argument('--team-id', default=os.environ.get('PROXIMUS_RELEASE_TEAM_ID'))
    parser.add_argument('--notary-profile', default=os.environ.get('PROXIMUS_NOTARY_PROFILE'))
    args = parser.parse_args()
    version = (ROOT / 'VERSION').read_text().strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid VERSION')
    app = (args.app or ROOT / f'build/{"local" if args.local else "macos"}/Build/Products/Release/Proximus.app').resolve()
    if not (app / 'Contents/Info.plist').is_file():
        raise ValueError(f'Build the app first: bash scripts/build.sh {"local" if args.local else "macos"}')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != version:
        raise ValueError('App version differs from VERSION. Rebuild before packaging.')
    commit = run('git', 'rev-parse', 'HEAD', capture=True).decode().strip()
    if not args.local:
        if not args.team_id or not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
            raise ValueError('Set PROXIMUS_RELEASE_TEAM_ID to the Apple Developer team ID')
        if run('git', 'status', '--porcelain', '--untracked-files=normal', capture=True).strip():
            raise ValueError('Commit the reviewed source before building a public release')
        if info.get('ProximusSourceRevision') != commit or info.get('ProximusSourceDirty') != 'false':
            raise ValueError('Rebuild from this clean source commit before public packaging')
        identity = signature(app, args.team_id)
        extension = app / 'Contents/PlugIns/ProximusAutoFill.appex'
        if not extension.is_dir():
            raise ValueError('The public application must include its provisioned AutoFill extension')
        signature(extension, args.team_id)
        for code in (app, extension):
            raw = run('codesign', '--display', '--entitlements', ':-', code, capture=True)
            entitlements = plistlib.loads(raw)
            if entitlements.get('get-task-allow') or entitlements.get('com.apple.security.get-task-allow'):
                raise ValueError('Debug entitlements are not allowed in a public release')
    else:
        run('codesign', '--verify', '--strict', '--deep', app)
    output = ROOT / ('dist/local' if args.local else 'dist')
    output.mkdir(parents=True, exist_ok=True)
    name = f'Proximus-{version}-macOS{"-local" if args.local else ""}.dmg'
    destination = output / name
    if destination.exists() and not args.local:
        raise ValueError('This version already has a packaged DMG. Release artifacts are immutable.')
    (ROOT / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='package-', dir=ROOT / 'build') as working:
        work = Path(working)
        stage = work / 'volume'
        stage.mkdir()
        staged_app = stage / 'Proximus.app'
        run('ditto', app, staged_app)
        if not args.local:
            stapled = subprocess.run(['xcrun', 'stapler', 'validate', str(staged_app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if not stapled:
                archive = work / 'notarization.zip'
                run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', staged_app, archive)
                notarize(archive, args.notary_profile, ROOT / 'build/notary-app.json')
                run('xcrun', 'stapler', 'staple', staged_app)
            run('xcrun', 'stapler', 'validate', staged_app)
            run('spctl', '--assess', '--type', 'execute', staged_app)
        (stage / 'Applications').symlink_to('/Applications')
        icon = staged_app / 'Contents/Resources/AppIcon.icns'
        if icon.is_file():
            shutil.copy2(icon, stage / '.VolumeIcon.icns')
            run('xcrun', 'SetFile', '-a', 'C', stage)
        dmg = work / name
        run('hdiutil', 'create', '-volname', 'Proximus', '-srcfolder', stage, '-fs', 'HFS+', '-format', 'UDZO', dmg)
        run('hdiutil', 'verify', dmg)
        if not args.local:
            run('codesign', '--force', '--sign', identity, '--timestamp', dmg)
            notarize(dmg, args.notary_profile, ROOT / 'build/notary-dmg.json')
            run('xcrun', 'stapler', 'staple', dmg)
            run('xcrun', 'stapler', 'validate', dmg)
            signature(dmg, args.team_id)
        if dmg.stat().st_size > 64 * 1024 * 1024:
            raise ValueError('DMG exceeds the website download verification limit of 64 MiB')
        os.replace(dmg, destination)
    manifest = dict(version=version, filename=name, sha256=sha256(destination), bytes=destination.stat().st_size,
                    sourceCommit=info.get('ProximusSourceRevision'), distribution='local' if args.local else 'developer-id')
    if not args.local:
        manifest['url'] = f'https://github.com/{REPOSITORY}/releases/download/v{version}/{name}'
    destination.with_name(name + '.release.json').write_text(json.dumps(manifest, indent=2) + '\n')
    destination.with_name(name + '.sha256').write_text(f'{manifest["sha256"]}  {name}\n')
    if not args.local:
        (output / f'Proximus-{version}-dependencies.json').write_bytes(run('cargo', 'metadata', '--locked', '--format-version', '1', capture=True))
    print(f'Created {destination}')
    if args.local:
        print('Local ad-hoc package. Public download and publication tools reject this artifact. Developer ID signing and notarization are required for normal distribution.')
    else:
        print('Developer ID signature, Apple notarization, disk image, checksum, and source revision verified.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Packaging stopped: {error}')
