#!/usr/bin/env python3
"""Archive and export a signed Mac app or iOS IPA with the maintainer's Apple team."""
import argparse
import os
import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['macos', 'ios'])
    parser.add_argument('--upload', action='store_true', help='Upload the iOS archive to App Store Connect instead of exporting an IPA')
    args = parser.parse_args()
    team = os.environ.get('PROXIMUS_RELEASE_TEAM_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Set PROXIMUS_RELEASE_TEAM_ID after Apple Developer enrollment and signing setup')
    if args.upload and args.platform != 'ios':
        raise ValueError('--upload applies to iPhone/iPad builds only')
    if run('git', 'status', '--porcelain', '--untracked-files=normal', capture=True).strip():
        raise ValueError('Commit the reviewed source before creating a distribution archive')
    revision = run('git', 'rev-parse', 'HEAD', capture=True).decode().strip()
    # Build every crypto slice and regenerate the checked-in project from source.
    run('bash', 'scripts/bootstrap.sh')
    if run('git', 'status', '--porcelain', '--untracked-files=normal', capture=True).strip():
        raise ValueError('Project generation changed tracked source. Review and commit it, then run again.')
    platform = 'macOS' if args.platform == 'macos' else 'iOS'
    out = ROOT / 'build/distribution' / args.platform
    out.mkdir(parents=True, exist_ok=True)
    archive = out / 'Proximus.xcarchive'
    if archive.exists():
        raise ValueError(f'Archive already exists at {archive}. Move it aside before building another release.')
    options = {'method': 'developer-id' if args.platform == 'macos' else 'app-store-connect',
               'teamID': team, 'signingStyle': 'automatic', 'destination': 'upload' if args.upload else 'export',
               'manageAppVersionAndBuildNumber': False}
    if args.platform == 'macos':
        options['signingCertificate'] = 'Developer ID Application'
    else:
        options['uploadSymbols'] = True
    export_options = out / 'ExportOptions.plist'
    export_options.write_bytes(plistlib.dumps(options))
    settings = [f'DEVELOPMENT_TEAM={team}', f'PROXIMUS_SOURCE_REVISION={revision}', 'PROXIMUS_SOURCE_DIRTY=false']
    if build := os.environ.get('PROXIMUS_BUILD_NUMBER'):
        if not re.fullmatch(r'[1-9][0-9]{0,8}', build):
            raise ValueError('PROXIMUS_BUILD_NUMBER must be a positive integer of at most nine digits')
        settings.append(f'CURRENT_PROJECT_VERSION={build}')
    run('xcodebuild', '-project', 'ProximusPasswords.xcodeproj', '-scheme', f'ProximusPasswords-{platform}',
        '-configuration', 'Release', '-destination', f'generic/platform={platform}', '-archivePath', archive,
        '-allowProvisioningUpdates', *settings, 'archive')
    run('xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', out,
        '-exportOptionsPlist', export_options, '-allowProvisioningUpdates')
    if args.upload:
        print('Uploaded to App Store Connect. Complete TestFlight processing and external review before sharing an invitation.')
    else:
        print(f'Exported distribution build: {out}')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Archive stopped: {error}')
