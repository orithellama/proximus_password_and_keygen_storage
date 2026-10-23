#!/usr/bin/env python3
"""Publish the verified DMG and release text to GitHub Releases, or keep a draft."""
import argparse
import json
import os
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path
from release_artifacts import REPOSITORY, validate_release

ROOT = Path(__file__).resolve().parents[1]


def run(*args, capture=False):
    result = subprocess.run([str(a) for a in args], cwd=ROOT, check=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else None


def verify_signature(path, team):
    run('codesign', '--verify', '--strict', '--deep', path)
    output = subprocess.run(['codesign', '--display', '--verbose=4', str(path)], capture_output=True, text=True, check=True).stderr
    if f'TeamIdentifier={team}\n' not in output or 'Authority=Developer ID Application:' not in output:
        raise ValueError('Unexpected release signing identity')
    run('xcrun', 'stapler', 'validate', path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--draft', action='store_true')
    args = parser.parse_args()
    version = (ROOT / 'VERSION').read_text().strip()
    manifest_path = ROOT / 'dist' / f'Proximus-{version}-macOS.dmg.release.json'
    release, artifact = validate_release(manifest_path)
    team = os.environ.get('PROXIMUS_RELEASE_TEAM_ID', '')
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ValueError('Set PROXIMUS_RELEASE_TEAM_ID before publishing')
    if run('git', 'status', '--porcelain', '--untracked-files=normal', capture=True).strip():
        raise ValueError('The working tree must be clean before publishing')
    if release['sourceCommit'] != run('git', 'rev-parse', 'HEAD', capture=True).decode().strip():
        raise ValueError('Release was built from another source commit')
    verify_signature(artifact, team)
    with tempfile.TemporaryDirectory(prefix='verify-release-', dir=ROOT / 'build') as folder:
        mount = Path(folder) / 'mounted'
        mount.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, artifact)
        try:
            app = mount / 'Proximus.app'
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            if info.get('ProximusSourceRevision') != release['sourceCommit'] or info.get('ProximusSourceDirty') != 'false' or info.get('CFBundleShortVersionString') != version:
                raise ValueError('Packaged app version/source does not match the release')
            verify_signature(app, team)
            run('spctl', '--assess', '--type', 'execute', app)
        finally:
            run('hdiutil', 'detach', mount)
    run('gh', 'auth', 'status')
    remote = json.loads(run('gh', 'api', f'repos/{REPOSITORY}/commits/{release["sourceCommit"]}', capture=True))
    if remote.get('sha') != release['sourceCommit']:
        raise ValueError('Push the reviewed source commit before creating its release')
    tag = 'v' + version
    existing = subprocess.run(['gh', 'api', f'repos/{REPOSITORY}/git/ref/tags/{tag}'], capture_output=True, text=True)
    if existing.returncode == 0:
        raise ValueError('This release tag already exists. Publication does not reuse or overwrite tags.')
    if '(HTTP 404)' not in existing.stderr:
        raise ValueError('Could not verify that the release tag is available')
    run('python3', 'scripts/prepare-release-notes.py')
    notes = ROOT / 'dist' / f'Proximus-{version}-release-notes.txt'
    checksum = artifact.with_name(artifact.name + '.sha256')
    expected = f'{release["sha256"]}  {artifact.name}\n'
    if checksum.read_text() != expected:
        raise ValueError('Checksum sidecar differs from the release manifest')
    dependencies = ROOT / 'dist' / f'Proximus-{version}-dependencies.json'
    if not dependencies.is_file():
        raise ValueError('Dependency manifest is missing')
    # Keep the release private until every asset is uploaded. Never overwrite an existing tag/release.
    run('gh', 'release', 'create', tag, artifact, checksum, manifest_path, dependencies,
        '--repo', REPOSITORY, '--draft', '--target', release['sourceCommit'], '--title', f'Proximus {version}', '--notes-file', notes)
    if not args.draft:
        run('gh', 'release', 'edit', tag, '--repo', REPOSITORY, '--draft=false', '--latest')
    print(f'https://github.com/{REPOSITORY}/releases/tag/{tag}')
    print('Website download configuration (pin only after the release is public):')
    print(json.dumps({key: release[key] for key in ('version', 'filename', 'url', 'sha256', 'bytes')}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Publication stopped: {error}')
