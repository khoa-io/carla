import gzip
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET


spec = importlib.util.spec_from_file_location('mac_gitdeps', Path(__file__).parents[1] / 'MacFetchDependencies.py')
gitdeps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gitdeps)


class GitDependenciesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.engine = self.root / 'engine'
        self.engine.mkdir()
        self.cache = self.root / 'packs'
        self.cache.mkdir()
        payload = b'header00' + b'native dependency'
        blob_hash = hashlib.sha1(payload[8:]).hexdigest()
        pack_hash = hashlib.sha1(payload).hexdigest()
        compressed = gzip.compress(payload)
        self.pack = self.cache / (pack_hash + '.pack')
        self.pack.write_bytes(compressed)
        tree = ET.Element('DependencyManifest', BaseUrl='https://example.invalid')
        files = ET.SubElement(tree, 'Files')
        for name in ['Engine/Mac/library.a', 'Engine/Mac/tool', 'Engine/Win64/library.a']:
            ET.SubElement(files, 'File', Name=name, Hash=blob_hash, IsExecutable=str(name.endswith('tool')).lower())
        blobs = ET.SubElement(tree, 'Blobs')
        ET.SubElement(blobs, 'Blob', Hash=blob_hash, Size=str(len(payload) - 8), PackHash=pack_hash, PackOffset='8')
        packs = ET.SubElement(tree, 'Packs')
        ET.SubElement(packs, 'Pack', Hash=pack_hash, Size=str(len(payload)), CompressedSize=str(len(compressed)), RemotePath='test')
        self.manifest = self.root / 'manifest.xml'
        ET.ElementTree(tree).write(self.manifest)

    def test_selected_blobs_aliases_permissions_and_repeat(self):
        result = gitdeps.fetch(self.engine, self.manifest, self.cache, excludes=['Win64'])
        self.assertEqual(result['installed_files'], 2)
        self.assertEqual((self.engine / 'Engine/Mac/library.a').read_bytes(), b'native dependency')
        self.assertTrue((self.engine / 'Engine/Mac/tool').stat().st_mode & 0o111)
        self.assertFalse((self.engine / 'Engine/Win64/library.a').exists())
        result = gitdeps.fetch(self.engine, self.manifest, self.cache, excludes=['Win64'])
        self.assertEqual(result['pending_files'], 0)

    def test_corrupt_pack_does_not_publish_files(self):
        self.pack.write_bytes(gzip.compress(b'corrupt'))
        with self.assertRaisesRegex(ValueError, 'integrity'):
            gitdeps.fetch(self.engine, self.manifest, self.cache)
        self.assertFalse((self.engine / 'Engine/Mac/library.a').exists())

    def test_dry_run_does_not_write_files(self):
        result = gitdeps.fetch(self.engine, self.manifest, self.cache, dry_run=True)
        self.assertEqual(result['selected_files'], 3)
        self.assertFalse((self.engine / 'Engine').exists())

    def test_existing_changes_are_preserved(self):
        destination = self.engine / 'Engine/Mac/library.a'
        destination.parent.mkdir(parents=True)
        destination.write_bytes(b'local change')
        with self.assertRaisesRegex(ValueError, 'Existing dependency differs'):
            gitdeps.fetch(self.engine, self.manifest, self.cache)
        self.assertEqual(destination.read_bytes(), b'local change')

    def test_path_traversal_is_rejected(self):
        for name in ['../escape', '/absolute', 'Engine/../../escape']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                gitdeps.safe_destination(self.engine, name)

    def test_budget_prevents_extraction(self):
        with self.assertRaisesRegex(ValueError, 'budget'):
            gitdeps.fetch(self.engine, self.manifest, self.cache, max_output_gb=0)
        self.assertFalse((self.engine / 'Engine').exists())


if __name__ == '__main__':
    unittest.main()
