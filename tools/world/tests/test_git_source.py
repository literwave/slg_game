import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from git_source import fetch_source


class GitSourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / 'client'
        self.repo.mkdir()
        self.git('init', '-b', 'master')
        self.git('config', 'uploadpack.allowFilter', 'true')
        self.git('config', 'uploadpack.allowAnySHA1InWant', 'true')
        (self.repo / 'map.json').write_text('{"city":"first"}\n')
        (self.repo / 'unrelated-art.bin').write_bytes(b'not a map')
        self.commit()
        self.first = self.git('rev-parse', 'HEAD').strip()
        self.url = self.repo.as_uri()

    def git(self, *args):
        result = subprocess.run(['git', '-C', str(self.repo), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def commit(self):
        self.git('add', '.')
        self.git('-c', 'user.name=地图工具测试', '-c', 'user.email=map-test@example.invalid',
                 'commit', '-m', '保存测试地图快照')

    def test_fetch_only_requested_files_and_record_commit(self):
        with fetch_source(self.url, 'master', ['map.json']) as (source, info):
            self.assertEqual(info['commit'], self.first)
            self.assertEqual(json.loads((source / 'map.json').read_text())['city'], 'first')
            self.assertFalse((source / 'unrelated-art.bin').exists())
            captured = source
        self.assertFalse(captured.exists())

    def test_uncommitted_local_changes_are_not_exported(self):
        (self.repo / 'map.json').write_text('{"city":"uncommitted"}\n')
        with fetch_source(self.url, 'master', ['map.json']) as (source, _):
            self.assertEqual(json.loads((source / 'map.json').read_text())['city'], 'first')

    def test_pinned_commit_does_not_follow_branch_advance(self):
        (self.repo / 'map.json').write_text('{"city":"second"}\n')
        self.commit()
        with fetch_source(self.url, self.first, ['map.json']) as (source, info):
            self.assertEqual(info['commit'], self.first)
            self.assertEqual(json.loads((source / 'map.json').read_text())['city'], 'first')
        with fetch_source(self.url, 'master', ['map.json']) as (source, info):
            self.assertNotEqual(info['commit'], self.first)
            self.assertEqual(json.loads((source / 'map.json').read_text())['city'], 'second')

    def test_missing_file_or_ref_fails_without_using_other_data(self):
        with self.assertRaisesRegex(ValueError, '缺少地图文件'):
            with fetch_source(self.url, 'master', ['missing.json']):
                self.fail('must reject missing source')
        with self.assertRaises(ValueError):
            with fetch_source(self.url, 'missing-branch', ['map.json']):
                self.fail('must reject missing ref')


if __name__ == '__main__':
    unittest.main()
