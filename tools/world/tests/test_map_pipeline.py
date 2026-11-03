"""小地图验证破坏场景；百万格集成验证用 make map / map-check。"""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
from map_core import canonical, digest, has_run, server_files, terrain_snapshot, tmx_bytes, validate, validate_tmx
spec = importlib.util.spec_from_file_location('map_cli', HERE / 'map.py')
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)


def fixture():
    width, height = 12, 12
    cells = [[0, 0] for _ in range(width * height)]
    cells[13] = [51, 4]
    cells[0] = [52, 4]
    empty = []
    for i in range(len(cells)):
        if i in (0, 13):
            continue
        found = False
        for n in range(12):
            value = (n + i * 7) % 12
            cells[i] = [52 + value % 4, 1 + value // 4]
            if not has_run(cells, i, width, height):
                found = True
                break
        if not found:
            cells[i] = [0, 0]; empty.append(i)
    snapshot = {'world': {'width': width, 'height': height, 'title': '测试地图', 'seed': 10, 'topologyVersion': 2,
                         'regionRows': [[width, 0] for _ in range(height)],
                         'regions': [{'id': 0, 'x': 1, 'y': 1, 'color': '#899975'}],
                         'cities': [{'id': 'city-00', 'name': '测试城', 'x': 1, 'y': 1, 'region': 0, 'level': 4, 'footprintRadius': 0}], 'gates': []},
                'landscape': {'width': width, 'height': height, 'seed': 10, 'topologyVersion': 2,
                              'riverCells': [], 'mountainCells': [], 'bridgeWaterCells': []},
                'resources': {'w': width, 'h': height, 'list': cells, 'emptyCells': empty},
                'fixed': {'birth': {'minDistance': 8, 'advancedMinDistance': 28, 'level6MinDistance': 48,
                                    'points': [{'id': 'fixed-1', 'x': 0, 'y': 0, 'type': 52, 'level': 4, 'region': 0}]},
                          'inner': {'points': [], 'spacing': {}}}}
    return {'width': width, 'height': height, 'seed': 10, 'maxBirthDensityRatio': 1.25}, snapshot


class MapRulesTests(unittest.TestCase):
    def test_valid_map_and_zero_based_lua(self):
        profile, snapshot = fixture()
        self.assertEqual(validate(snapshot, profile)['fixedResources'], 1)
        lua = server_files(snapshot)['server/mapRes_0.lua']
        self.assertIn(b'[0]={52,4}', lua)
        self.assertIn(b'[13]={51,4}', lua)

    def test_validation_never_changes_client_data(self):
        profile, snapshot = fixture()
        before = canonical(snapshot)
        validate(snapshot, profile)
        server_files(snapshot)
        self.assertEqual(canonical(snapshot), before)

    def test_client_city_without_id_is_preserved(self):
        profile, snapshot = fixture()
        del snapshot['world']['cities'][0]['id']
        validate(snapshot, profile)
        self.assertNotIn('id', snapshot['world']['cities'][0])

    def test_actual_client_tmx_mismatch_is_rejected(self):
        _, snapshot = fixture()
        tmx = tmx_bytes(snapshot)
        validate_tmx(tmx, snapshot)
        changed = tmx.replace(b'<data encoding="csv">0,', b'<data encoding="csv">1,', 1)
        with self.assertRaisesRegex(ValueError, 'TMX'):
            validate_tmx(changed, snapshot)

    def test_fixed_resource_cannot_be_changed(self):
        profile, snapshot = fixture()
        snapshot['resources']['list'][0] = [53, 4]
        with self.assertRaisesRegex(ValueError, '固定资源被移动或改写'):
            validate(snapshot, profile)

    def test_city_cannot_overlap_mountain(self):
        profile, snapshot = fixture()
        snapshot['landscape']['mountainCells'] = [13]
        with self.assertRaisesRegex(ValueError, '城池占地冲突'):
            validate(snapshot, profile)

    def test_walkable_island_is_rejected(self):
        profile, snapshot = fixture()
        blocked = [y * 12 + 6 for y in range(12)]
        snapshot['landscape']['mountainCells'] = blocked
        for i in blocked:
            snapshot['resources']['list'][i] = [0, 0]
        snapshot['resources']['emptyCells'] = [i for i in snapshot['resources']['emptyCells'] if i not in blocked]
        with self.assertRaisesRegex(ValueError, '孤立地块'):
            validate(snapshot, profile)

    def test_spawn_assignment_is_not_static_map_data(self):
        profile, snapshot = fixture()
        snapshot['world']['spawnZones'] = []
        with self.assertRaisesRegex(ValueError, '玩家出生分配'):
            validate(snapshot, profile)

    def test_output_path_boundaries(self):
        with self.assertRaises(ValueError):
            cli.output_root('res/map')

    def test_server_comparison_catches_actual_cell_difference(self):
        _, snapshot = fixture()
        actual = {'resources': copy.deepcopy(snapshot['resources']), 'world': copy.deepcopy(snapshot['world']),
                  'terrain': terrain_snapshot(snapshot)}
        self.assertTrue(cli.compare_server(snapshot, actual)['matching'])
        actual['resources']['list'][0] = [53, 4]
        report = cli.compare_server(snapshot, actual)
        self.assertFalse(report['matching'])
        self.assertEqual(report['differentResourceCells'], 1)

    def test_server_comparison_catches_terrain_and_city_drift(self):
        _, snapshot = fixture()
        actual = {'resources': copy.deepcopy(snapshot['resources']), 'world': copy.deepcopy(snapshot['world']),
                  'terrain': terrain_snapshot(snapshot)}
        actual['terrain']['blockedCells'] = [0]
        actual['world']['cities'][0]['name'] = '错误城池'
        report = cli.compare_server(snapshot, actual)
        self.assertFalse(report['matching'])
        self.assertFalse(report['terrainMatches'])
        self.assertFalse(report['campaignMatches'])


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.profile, self.snapshot = fixture()
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.out = Path(self.root.name) / 'maps'
        self.config = {'hashes': {}, 'requirements': []}
        self.client = Path(self.root.name) / 'client-project'
        self.original_load_client = cli.load_client
        self.write_client()

    def write_client(self):
        values = {key: self.snapshot[key] for key in ('world', 'resources', 'landscape')}
        values.update(self.snapshot['fixed'])
        values.update(landTypes=[], landConfig=[])
        for key, relative in cli.SOURCE_PATHS.items():
            path = self.client / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(tmx_bytes(self.snapshot) if key == 'tmx' else json.dumps(values[key], ensure_ascii=False, indent=2).encode('utf8'))

    def load_client(self, directory):
        _, snapshot, raw, hashes = self.original_load_client(directory)
        return self.profile, snapshot, raw, hashes

    def build(self):
        args = cli.parser().parse_args(['build'])
        with patch.object(cli, 'load_client', side_effect=self.load_client), \
             patch.object(cli, 'land_config', return_value=self.config), \
             patch.object(cli, 'output_root', return_value=self.out), \
             patch.object(cli, 'ROOT', Path(self.root.name)), contextlib.redirect_stdout(io.StringIO()):
            cli.build_from_source(args, self.client, {'repository': 'fixture.git', 'requestedRef': 'master', 'commit': 'a' * 40})
        revision = json.loads((self.out / 'latest.json').read_text())['mapRevision']
        return self.out / revision

    def test_full_package_repeat_is_identical_and_does_not_rewrite(self):
        first = self.build()
        archive = first / 'map-package.zip'
        before, modified = archive.read_bytes(), archive.stat().st_mtime_ns
        self.assertEqual(self.build(), first)
        self.assertEqual(archive.read_bytes(), before)
        self.assertEqual(archive.stat().st_mtime_ns, modified)
        with zipfile.ZipFile(archive) as z:
            self.assertTrue(all(i.date_time == (2000, 1, 1, 0, 0, 0) for i in z.infolist()))
        self.assertFalse((Path(self.root.name) / 'res').exists())

    def test_changed_client_source_creates_new_immutable_revision(self):
        first = self.build()
        first_bytes = (first / 'manifest.json').read_bytes()
        self.snapshot['world']['cities'][0]['name'] = '新的客户端城名'
        self.write_client()
        second = self.build()
        self.assertNotEqual(first, second)
        self.assertEqual((first / 'manifest.json').read_bytes(), first_bytes)
        self.assertEqual(json.loads((second / 'client/world/campaign-map.json').read_text())['cities'][0]['name'], '新的客户端城名')

    def test_client_files_are_byte_identical(self):
        directory = self.build()
        for key, exported in cli.EXPORT_PATHS.items():
            self.assertEqual((directory / exported).read_bytes(), (self.client / cli.SOURCE_PATHS[key]).read_bytes())
        self.assertEqual(json.loads((directory / 'diff.json').read_text())['changedCells'], 0)

    def test_fresh_build_in_another_directory_has_identical_zip(self):
        first = self.build()
        before = (first / 'map-package.zip').read_bytes()
        self.out = Path(self.root.name) / 'second-output'
        second = self.build()
        self.assertEqual(first.name, second.name)
        self.assertEqual(before, (second / 'map-package.zip').read_bytes())

    def test_corruption_is_rejected(self):
        directory = self.build()
        with (directory / 'server/terrain.lua').open('ab') as f:
            f.write(b'-- unexpected edit')
        with self.assertRaisesRegex(ValueError, '文件校验失败'):
            cli.check_package(directory, check_config=False)

    def test_exported_client_copy_cannot_be_changed_even_with_updated_file_hash(self):
        directory = self.build()
        path = directory / 'client/config/mapRes_0.json'
        # 格式变化也不能冒充客户端原文件；不能只更新文件校验值掩盖差异。
        path.write_bytes(canonical(self.snapshot['resources']))
        manifest_path = directory / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['files']['client/config/mapRes_0.json'] = digest(path.read_bytes())
        manifest_path.write_bytes(canonical(manifest))
        with self.assertRaisesRegex(ValueError, '客户端源文件被改写'):
            cli.check_package(directory, check_config=False)

    def test_failed_validation_does_not_publish_latest(self):
        directory = self.build()
        before = (self.out / 'latest.json').read_bytes()
        self.snapshot['resources']['list'][0] = [55, 4]
        self.write_client()
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual((self.out / 'latest.json').read_bytes(), before)
        self.assertTrue(directory.is_dir())
        self.assertFalse(list(self.out.glob('.candidate-*')))

    def test_check_detects_client_changed_after_export(self):
        directory = self.build()
        path = self.client / cli.SOURCE_PATHS['world']
        path.write_bytes(path.read_bytes() + b'\n')
        with self.assertRaisesRegex(ValueError, '客户端地图已变化'):
            cli.check_package(directory, check_config=False, client=self.client)

    def test_client_change_during_export_does_not_publish(self):
        original = cli.preview_files
        def change_source(*args):
            path = self.client / cli.SOURCE_PATHS['world']
            path.write_bytes(path.read_bytes() + b'\n')
            return original(*args)
        with patch.object(cli, 'preview_files', side_effect=change_source):
            with self.assertRaisesRegex(ValueError, '客户端地图已变化'):
                self.build()
        self.assertFalse((self.out / 'latest.json').exists())
        self.assertFalse(list(self.out.glob('.candidate-*')))

    def test_seed_and_profile_options_are_rejected(self):
        with patch.dict('os.environ', {'SEED': '20261103'}):
            with self.assertRaisesRegex(ValueError, '不支持 SEED'):
                self.build()
        with patch.dict('os.environ', {'PROFILE': 's1'}):
            with self.assertRaisesRegex(ValueError, '不支持 PROFILE'):
                self.build()
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                cli.parser().parse_args(['build', '--seed', '1'])
        self.assertFalse(self.out.exists())

    def test_legacy_random_package_is_rejected(self):
        directory = self.build()
        path = directory / 'manifest.json'
        manifest = json.loads(path.read_bytes())
        manifest['schemaVersion'] = 3
        path.write_bytes(canonical(manifest))
        with self.assertRaisesRegex(ValueError, '旧生成包不能使用'):
            cli.check_package(directory, check_config=False)


if __name__ == '__main__':
    unittest.main()
