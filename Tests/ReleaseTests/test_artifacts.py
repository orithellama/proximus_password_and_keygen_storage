import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from release_artifacts import REPOSITORY, sha256, validate_release


class ReleaseArtifactTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.artifact = root / 'Proximus-0.3.1-macOS.dmg'
        self.artifact.write_bytes(b'release byte fixture, not an executable disk image')
        self.manifest = root / (self.artifact.name + '.release.json')
        self.value = dict(version='0.3.1', filename=self.artifact.name, distribution='developer-id',
                          sourceCommit='a' * 40, sha256=sha256(self.artifact), bytes=self.artifact.stat().st_size,
                          url=f'https://github.com/{REPOSITORY}/releases/download/v0.3.1/{self.artifact.name}')
        self.save()

    def save(self):
        self.manifest.write_text(json.dumps(self.value))

    def test_exact_artifact_matches_manifest(self):
        manifest, artifact = validate_release(self.manifest)
        self.assertEqual(manifest['sha256'], sha256(artifact))

    def test_modified_bytes_are_rejected(self):
        self.artifact.write_bytes(b'x' * self.artifact.stat().st_size)
        with self.assertRaisesRegex(ValueError, 'checksum'):
            validate_release(self.manifest)

    def test_local_package_is_never_a_public_release(self):
        self.value['distribution'] = 'local'
        self.save()
        with self.assertRaisesRegex(ValueError, 'Developer ID'):
            validate_release(self.manifest)

    def test_changed_repository_or_filename_is_rejected(self):
        self.value['url'] = self.value['url'].replace(REPOSITORY, 'attacker/replacement')
        self.save()
        with self.assertRaisesRegex(ValueError, 'URL'):
            validate_release(self.manifest)
        self.value['filename'] = '../Proximus.dmg'
        self.save()
        with self.assertRaises(ValueError):
            validate_release(self.manifest)

    def test_missing_source_commit_or_wrong_size_is_rejected(self):
        self.value['sourceCommit'] = ''
        self.save()
        with self.assertRaisesRegex(ValueError, 'source commit'):
            validate_release(self.manifest)
        self.value['sourceCommit'] = 'a' * 40
        self.value['bytes'] += 1
        self.save()
        with self.assertRaisesRegex(ValueError, 'size'):
            validate_release(self.manifest)
