#!/usr/bin/env python3
"""make map / map-check / map-diff 的独立入口，Python 3.10+。"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

from map_core import (ENUMS, canonical, digest, lua_module, preview_files, read_json,
                      require, server_files, snapshot_diff, terrain_snapshot, validate, validate_tmx)
from git_source import fetch_source

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
HEX = re.compile(r'^[0-9a-f]{64}$')
SOURCE_PATHS = {
    'world': 'assets/resources/world/campaign-map.json',
    'landscape': 'assets/resources/world/original-landscape.json',
    'resources': 'assets/resources/config/mapRes_0.json',
    'tmx': 'assets/resources/world/map.tmx',
    'birth': 'tools/world/fixed-birth-resources.json',
    'inner': 'tools/world/fixed-inner-resources.json',
    'landTypes': 'assets/resources/config/ResLandType.json',
    'landConfig': 'assets/resources/config/ResLand.json',
}
EXPORT_PATHS = {
    'world': 'client/world/campaign-map.json',
    'landscape': 'client/world/original-landscape.json',
    'resources': 'client/config/mapRes_0.json',
    'tmx': 'client/world/map.tmx',
    'birth': 'inputs/fixed-birth-resources.json',
    'inner': 'inputs/fixed-inner-resources.json',
}


def lua_executable():
    lua = os.environ.get('MAP_LUA') or str(ROOT / 'skynet/3rd/lua/lua')
    if not Path(lua).is_file():
        lua = shutil.which('lua5.4') or shutil.which('lua')
    require(lua, '需要 Lua 5.4 读取服务端资源配置，请先 make 或设置 MAP_LUA')
    return lua


def land_config():
    directory = ROOT / 'game_common/server/res'
    lua = lua_executable()
    paths = [directory / name for name in ('ResLandType.lua', 'ResLand.lua')]
    result = subprocess.run([lua, str(HERE / 'read_land_config.lua'), *map(str, paths)],
                            capture_output=True, text=True, timeout=30)
    require(result.returncode == 0, '资源配置读取失败: ' + result.stderr.strip())
    enums, pairs = {}, set()
    for line in result.stdout.splitlines():
        kind, a, b = line.split()
        if kind == 'enum':
            enums[a] = int(b)
        else:
            pairs.add((int(a), int(b)))
    requirements = []
    for cell_type, name in ENUMS.items():
        require(name in enums, '资源枚举缺失: ' + name)
        for level in range(1, 11):
            require((enums[name], level) in pairs, f'资源配置缺失: {name} 等级 {level}')
        requirements.append({'cellType': cell_type, 'enum': name, 'type': enums[name], 'levels': list(range(1, 11))})
    return {'hashes': {p.name: digest(p.read_bytes()) for p in paths}, 'requirements': requirements}


def load_client(directory):
    raw = {key: (directory / path).read_bytes() for key, path in SOURCE_PATHS.items()}
    snapshot = {key: json.loads(raw[key]) for key in ('world', 'landscape', 'resources')}
    snapshot['fixed'] = {key: json.loads(raw[key]) for key in ('birth', 'inner')}
    settings = {'schemaVersion': 1, 'width': 1000, 'height': 1000, 'maxBirthDensityRatio': 1.25}
    hashes = {SOURCE_PATHS[key]: digest(data) for key, data in raw.items()}
    return settings, snapshot, raw, hashes


def check_client_config(raw, config):
    def rows(key):
        value = json.loads(raw[key])
        return value.values() if isinstance(value, dict) else value
    types = {row['Enum']: row['Id'] for row in rows('landTypes')}
    pairs = {(row['Type'], row['Level']) for row in rows('landConfig')}
    for rule in config['requirements']:
        require(types.get(rule['enum']) == rule['type'], '客户端与服务器资源类型协议不同: ' + rule['enum'])
        require(all((rule['type'], level) in pairs for level in rule['levels']), '客户端缺少资源等级配置: ' + rule['enum'])


def check_source_hashes(directory, hashes):
    require(set(hashes) == set(SOURCE_PATHS.values()), '客户端源文件清单不完整')
    changed = [name for name, expected in hashes.items()
               if not (directory / name).is_file() or digest((directory / name).read_bytes()) != expected]
    require(not changed, '客户端地图已变化，请重新导出: ' + ', '.join(changed))


def reject_generation_options():
    require(not os.environ.get('SEED'), '不支持 SEED：地图只能从客户端原样导出，不能随机生成')
    require(not os.environ.get('PROFILE'), '不支持 PROFILE：请使用 CLIENT_REPO/CLIENT_REF 指定客户端 Git 地图源')
    require(not os.environ.get('CLIENT'), '不读取客户端工作区，请使用 CLIENT_REPO/CLIENT_REF 拉取已提交的地图')


def compare_server(snapshot, actual):
    expected = snapshot['resources']
    got = actual['resources']
    size_match = (expected['w'], expected['h'], len(expected['list'])) == (got['w'], got['h'], len(got['list']))
    different = sum(a != b for a, b in zip(expected['list'], got['list'])) + abs(len(expected['list']) - len(got['list']))
    empty_match = set(expected['emptyCells']) == set(got['emptyCells'])
    expected_terrain = terrain_snapshot(snapshot)
    terrain_match = all(set(actual['terrain'].get(key, [])) == set(value) if isinstance(value, list)
                        else actual['terrain'].get(key) == value for key, value in expected_terrain.items())
    world_match = actual['world'] == snapshot['world']
    return {'matching': size_match and different == 0 and empty_match and terrain_match and world_match,
            'comparedCells': len(expected['list']), 'differentResourceCells': different, 'sizeMatches': size_match,
            'emptyCellsMatch': empty_match, 'terrainMatches': terrain_match, 'campaignMatches': world_match}


def verify_server(args):
    reject_generation_options()
    with fetch_source(args.repo, args.ref, list(SOURCE_PATHS.values())) as (source, provenance):
        print('客户端 Git 提交: ' + provenance['commit'], flush=True)
        return verify_server_source(args, source, provenance)


def verify_server_source(args, source, provenance):
    settings, snapshot, raw, hashes = load_client(source)
    check_client_config(raw, land_config())
    validate(snapshot, settings)
    validate_tmx(raw['tmx'], snapshot)
    directory = (ROOT / args.server_map).resolve()
    result = subprocess.run([lua_executable(), str(HERE / 'read_server_map.lua'), str(ROOT), str(directory)],
                            capture_output=True, text=True, timeout=90)
    require(result.returncode == 0, '服务端地图读取失败: ' + result.stderr.strip())
    actual = json.loads(result.stdout)
    report = compare_server(snapshot, actual)
    check_source_hashes(source, hashes)
    report['serverMapRevision'] = actual['mapRevision']
    report['clientCommit'] = provenance['commit']
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['matching'] else 1


def output_root(value):
    path = (ROOT / value).resolve()
    require(path.is_relative_to(ROOT / 'build') and path != ROOT / 'build', 'OUT 必须位于后端 build/ 的子目录')
    return path


def resolve_package(value, out):
    if not value or value == 'latest':
        value = read_json(out / 'latest.json')['mapRevision']
    path = out / value if HEX.fullmatch(value) else Path(value)
    if not path.is_absolute():
        path = ROOT / path
    require(path.is_dir(), '找不到地图包: ' + str(value))
    return path.resolve()


def load_package_snapshot(directory):
    return {'world': read_json(directory / 'client/world/campaign-map.json'),
            'landscape': read_json(directory / 'client/world/original-landscape.json'),
            'resources': read_json(directory / 'client/config/mapRes_0.json'),
            'fixed': {key: read_json(directory / EXPORT_PATHS[key]) for key in ('birth', 'inner')}}


def revision_of(identity):
    return digest(canonical(identity))


def check_package(directory, check_config=True, client=None):
    manifest = read_json(directory / 'manifest.json')
    require(manifest.get('schemaVersion') == 4 and HEX.fullmatch(manifest.get('mapRevision', '')), '需要客户端固定地图导出包；旧生成包不能使用，请重新 make map')
    require(manifest['identity'].get('mode') == 'client-snapshot', '拒绝非客户端快照地图')
    provenance = manifest['identity'].get('clientGit', {})
    require(re.fullmatch(r'[0-9a-f]{40,64}', provenance.get('commit', '')) and provenance.get('repository'), '缺少客户端 Git 提交，请重新 make map')
    require(revision_of(manifest['identity']) == manifest['mapRevision'], '地图版本与构建输入不符')
    files = manifest['files']
    mandatory = {'server/mapRes_0.lua', 'server/campaign-map.lua', 'server/terrain.lua', 'server/manifest.lua',
                 'client/config/mapRes_0.json', 'client/world/campaign-map.json', 'client/world/original-landscape.json',
                 'client/world/map.tmx', 'client/world/map-version.json', 'inputs/fixed-birth-resources.json', 'inputs/fixed-inner-resources.json', 'inputs/validation.json',
                 'report.json', 'diff.json', 'preview.png', 'resources.png', 'preview.html'}
    require(mandatory <= files.keys(), '地图包缺少必需文件')
    for name, expected in files.items():
        path = directory / name
        require(not Path(name).is_absolute() and '..' not in Path(name).parts and path.resolve().is_relative_to(directory), '清单文件路径越界')
        require(path.is_file() and digest(path.read_bytes()) == expected, '文件校验失败: ' + name)
    identity = manifest['identity']
    require(identity['serverFiles'] == {name: files['server/' + name] for name in ('mapRes_0.lua', 'campaign-map.lua', 'terrain.lua')}, '服务端数据与版本不符')
    snapshot = load_package_snapshot(directory)
    settings = read_json(directory / 'inputs/validation.json')
    report = validate(snapshot, settings)
    validate_tmx((directory / 'client/world/map.tmx').read_bytes(), snapshot)
    require(read_json(directory / 'report.json') == report, '校验报告与地图不符')
    require((manifest['width'], manifest['height']) == (report['width'], report['height']), '清单尺寸不一致')
    version = read_json(directory / 'client/world/map-version.json')
    require(version['mapRevision'] == manifest['mapRevision'], '客户端版本不一致')
    require(version.get('clientCommit') == provenance['commit'], '客户端 Git 提交不一致')
    # 客户端原文件字节不变；Lua 必须与这些原文件中的数据完全一致。
    require(set(identity['sourceHashes']) == set(SOURCE_PATHS.values()), '源文件摘要清单不完整')
    for key, name in EXPORT_PATHS.items():
        require(files[name] == identity['sourceHashes'][SOURCE_PATHS[key]], '客户端源文件被改写: ' + name)
    for name, data in server_files(snapshot).items():
        require(digest(data) == files[name], '前后端数据不一致: ' + name)
    server_manifest = make_server_manifest(manifest)
    require((directory / 'server/manifest.lua').read_bytes() == lua_module(server_manifest), '服务端清单与总清单不一致')
    warnings = []
    if check_config:
        current = land_config()
        require(current['requirements'] == identity['config']['requirements'], '资源类型/等级协议与地图包不兼容')
        if current['hashes'] != identity['config']['hashes']:
            warnings.append('资源配置文件已变化；类型和等级仍兼容，生成新版本时将记录新的配置摘要')
    archive = directory / 'map-package.zip'
    require(archive.is_file(), '缺少地图压缩包')
    with zipfile.ZipFile(archive) as z:
        require(len(z.namelist()) == len(set(z.namelist())) and set(z.namelist()) == set(files) | {'manifest.json'}, '压缩包文件清单不符')
        for name in z.namelist():
            expected = digest((directory / 'manifest.json').read_bytes()) if name == 'manifest.json' else files[name]
            require(digest(z.read(name)) == expected, '压缩包内容不一致: ' + name)
    if client is not None:
        check_source_hashes(client, identity['sourceHashes'])
    return {'mapRevision': manifest['mapRevision'], 'checks': report['checks'],
            'clientCommit': provenance['commit'], 'clientSourceVerified': client is not None, 'warnings': warnings}


def make_server_manifest(manifest):
    return {'schemaVersion': 4, 'sourceMode': 'client-snapshot', 'mapRevision': manifest['mapRevision'], 'width': manifest['width'], 'height': manifest['height'],
            'clientCommit': manifest['identity']['clientGit']['commit'],
            'topologyVersion': manifest['topologyVersion'], 'cellIdFormula': 'y * width + x',
            'resourceRequirements': manifest['identity']['config']['requirements'],
            'files': manifest['identity']['serverFiles']}


def deterministic_zip(directory, files):
    with zipfile.ZipFile(directory / 'map-package.zip', 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, (directory / name).read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def build(args):
    reject_generation_options()
    print('拉取客户端 Git 地图: ' + args.ref, flush=True)
    with fetch_source(args.repo, args.ref, list(SOURCE_PATHS.values())) as (source, provenance):
        print('客户端 Git 提交: ' + provenance['commit'], flush=True)
        build_from_source(args, source, provenance)


def build_from_source(args, source, provenance):
    reject_generation_options()
    settings, snapshot, raw, source_hashes = load_client(source)
    config = land_config()
    check_client_config(raw, config)
    print('读取客户端固定地图；校验百万格资源、关口、城池与实际 TMX…', flush=True)
    report = validate(snapshot, settings)
    validate_tmx(raw['tmx'], snapshot)
    content = server_files(snapshot)
    content.update({name: raw[key] for key, name in EXPORT_PATHS.items()})
    generators = {p.name: digest(p.read_bytes()) for p in sorted(HERE.iterdir()) if p.suffix in ('.py', '.lua')}
    identity = {'mode': 'client-snapshot', 'exporterVersion': 3, 'exporterHashes': generators, 'clientGit': provenance,
                'sourceHashes': source_hashes, 'config': config,
                'serverFiles': {Path(name).name: digest(data) for name, data in content.items() if name.startswith('server/')}}
    revision = revision_of(identity)
    manifest = {'schemaVersion': 4, 'mapRevision': revision,
                'width': report['width'], 'height': report['height'], 'topologyVersion': snapshot['world'].get('topologyVersion', 1),
                'identity': identity}
    content['server/manifest.lua'] = lua_module(make_server_manifest(manifest))
    content['client/world/map-version.json'] = canonical({'schemaVersion': 1, 'mapRevision': revision, 'clientCommit': provenance['commit']})
    content['inputs/validation.json'] = canonical(settings)
    content['report.json'] = canonical(report)
    content['diff.json'] = canonical(dict(snapshot_diff(snapshot, snapshot), comparedWith='client-source'))
    content.update(preview_files(snapshot, report, revision))
    manifest['files'] = {name: digest(data) for name, data in sorted(content.items())}
    content['manifest.json'] = canonical(manifest)
    out = output_root(args.output)
    out.mkdir(parents=True, exist_ok=True)
    destination = out / revision
    if destination.exists():
        check_package(destination, client=source)
        require((destination / 'manifest.json').read_bytes() == content['manifest.json'], '同版本输出存在冲突，拒绝覆盖')
        print('相同输入已存在，复用已校验版本。', flush=True)
    else:
        # 候选目录失败即删除；只在全部校验成功后原子改名，不触碰 res/map。
        with tempfile.TemporaryDirectory(prefix='.candidate-', dir=out) as temporary:
            stage = Path(temporary) / 'package'
            for name, data in content.items():
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            deterministic_zip(stage, content)
            check_package(stage, client=source)
            try:
                stage.rename(destination)
            except OSError:
                if not destination.exists():
                    raise
                check_package(destination, client=source)
                require((destination / 'manifest.json').read_bytes() == content['manifest.json'], '并发构建版本冲突')
    check_source_hashes(source, source_hashes)
    with tempfile.NamedTemporaryFile(dir=out, prefix='.latest-', delete=False) as pointer:
        pointer.write(canonical({'mapRevision': revision, 'sourceMode': 'client-snapshot', 'clientCommit': provenance['commit']}))
        pointer_path = Path(pointer.name)
    os.replace(pointer_path, out / 'latest.json')
    print(json.dumps({'mapRevision': revision, 'package': str(destination.relative_to(ROOT)),
                      'preview': str((destination / 'preview.html').relative_to(ROOT)), 'clientCommit': provenance['commit'], 'clientSourceVerified': True, 'changedCells': 0}, ensure_ascii=False))


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    sub = cli.add_subparsers(dest='command', required=True)
    for name in ('build', 'check', 'diff', 'verify-server'):
        command = sub.add_parser(name)
        command.add_argument('--output', default=os.environ.get('OUT') or 'build/maps')
        if name == 'verify-server':
            command.add_argument('--server-map', default=os.environ.get('SERVER_MAP') or 'res/map')
        elif name == 'check':
            command.add_argument('--map', default=os.environ.get('MAP') or 'latest')
        elif name == 'diff':
            command.add_argument('--from', dest='before', default=os.environ.get('FROM'))
            command.add_argument('--to', dest='after', default=os.environ.get('TO') or 'latest')
        if name in ('build', 'verify-server'):
            command.add_argument('--repo', default=os.environ.get('CLIENT_REPO') or 'git@github.com:literwave/slg_game_client.git')
            command.add_argument('--ref', default=os.environ.get('CLIENT_REF') or 'master')
    return cli


def main():
    args = parser().parse_args()
    try:
        if args.command == 'build':
            build(args)
        elif args.command == 'check':
            reject_generation_options()
            directory = resolve_package(args.map, output_root(args.output))
            provenance = read_json(directory / 'manifest.json')['identity'].get('clientGit')
            require(provenance, '缺少客户端 Git 提交，请重新 make map')
            with fetch_source(provenance['repository'], provenance['commit'], list(SOURCE_PATHS.values())) as (source, _):
                print(json.dumps(check_package(directory, client=source), ensure_ascii=False))
        elif args.command == 'verify-server':
            return verify_server(args)
        else:
            require(args.before, '请指定 FROM=旧版本（或 --from）')
            out = output_root(args.output)
            before, after = resolve_package(args.before, out), resolve_package(args.after, out)
            check_package(before); check_package(after)
            result = snapshot_diff(load_package_snapshot(before), load_package_snapshot(after))
            result['from'] = read_json(before / 'manifest.json')['mapRevision']
            result['to'] = read_json(after / 'manifest.json')['mapRevision']
            print(json.dumps(result, ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print('地图操作失败: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
