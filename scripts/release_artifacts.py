"""Shared release validation. Only final Developer ID DMGs qualify for publication."""
import hashlib
import json
import re
from pathlib import Path

REPOSITORY = 'orithellama/proximus_password_and_keygen_storage'


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_release(manifest_path):
    manifest_path = Path(manifest_path)
    value = json.loads(manifest_path.read_text())
    version = value.get('version', '')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid release version')
    name = f'Proximus-{version}-macOS.dmg'
    if value.get('distribution') != 'developer-id' or value.get('filename') != name:
        raise ValueError('Only a Developer ID release DMG can be published')
    if value.get('url') != f'https://github.com/{REPOSITORY}/releases/download/v{version}/{name}':
        raise ValueError('Unexpected release download URL')
    if not re.fullmatch(r'[0-9a-f]{40}', value.get('sourceCommit', '')):
        raise ValueError('Missing source commit')
    if not re.fullmatch(r'[0-9a-f]{64}', value.get('sha256', '')):
        raise ValueError('Missing SHA-256 checksum')
    artifact = manifest_path.parent / name
    if artifact.is_symlink() or type(value.get('bytes')) is not int or not 0 < value['bytes'] <= 64 * 1024 * 1024:
        raise ValueError('Invalid release size or file')
    if artifact.stat().st_size != value['bytes'] or sha256(artifact) != value['sha256']:
        raise ValueError('Release artifact does not match its pinned checksum and size')
    return value, artifact
