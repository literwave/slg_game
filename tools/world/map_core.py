"""静态地图构建核心。只使用标准库，不连接游戏服务或数据库。"""
from array import array
from collections import Counter, defaultdict, deque
import gzip
import hashlib
import html
import json
import math
from pathlib import Path
import struct
import xml.etree.ElementTree as ET
import zlib

RESOURCE_TYPES = (52, 53, 54, 55)
DIRECTIONS = ((1, 0), (0, 1), (1, 1), (-1, 1))
ENUMS = {52: 'WOOD', 53: 'IRON', 54: 'STONE', 55: 'GRAIN'}


def require(ok, message):
    if not ok:
        raise ValueError(message)


def canonical(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')) + '\n').encode('utf8')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    path = Path(path)
    data = gzip.decompress(path.read_bytes()) if path.suffix == '.gz' else path.read_bytes()
    return json.loads(data)


def decode_regions(world):
    width, height = world['width'], world['height']
    valid = {r['id'] for r in world['regions']}
    require(bool(valid) and len(valid) == len(world['regions']) and valid <= set(range(256)), '州域 ID 缺失、重复或越界')
    if 'regionRows' not in world:
        # 已发布 v1 客户端按此公式查询州域；仅用于读回校验，不写入或改变地图。
        require(world.get('version') == 1 and (width, height) == (1000, 1000), '未知旧版州域格式')
        ids = bytearray()
        for y in range(height):
            for x in range(width):
                dx, dy = x - 499.5, y - 499.5
                radius = math.hypot(dx, dy)
                angle = math.atan2(dy, dx) % math.tau
                region = 9 if radius < 100 else 6 + int(angle / (math.tau / 3)) if radius < 285 else int(angle / (math.tau / 6))
                ids.append(region)
        return ids
    require(len(world['regionRows']) == height, '州域行数错误')
    ids = bytearray()
    for row in world['regionRows']:
        require(len(row) % 2 == 0, '州域 RLE 不完整')
        start = 0
        for end, region in zip(row[::2], row[1::2]):
            require(type(end) is int and start < end <= width and region in valid, '州域 RLE 无效')
            ids.extend(bytes([region]) * (end - start))
            start = end
        require(start == width, '州域 RLE 未覆盖整行')
    return ids


def has_run(cells, index, width, height):
    x, y = index % width, index // width
    for dx, dy in DIRECTIONS:
        for offset in (-2, -1, 0):
            sx, sy = x + offset * dx, y + offset * dy
            ex, ey = sx + 2 * dx, sy + 2 * dy
            if not (0 <= sx < width and 0 <= ex < width and 0 <= sy < height and 0 <= ey < height):
                continue
            a, b, c = (cells[(sy + step * dy) * width + sx + step * dx] for step in range(3))
            if all(p[0] in RESOURCE_TYPES for p in (a, b, c)):
                if a[0] == b[0] == c[0] or a[1] == b[1] == c[1]:
                    return True
    return False


def city_key(city):
    # 旧客户端城池没有 id；仅用于检查和差异索引，不修改导出的城池数据。
    return city.get('id', 'city-region-' + str(city['region']))


def cell_set(values, size, name):
    require(isinstance(values, list) and all(type(i) is int and 0 <= i < size for i in values), name + ' 索引越界')
    result = set(values)
    require(len(result) == len(values), name + ' 索引重复')
    return result


def validate(snapshot, profile, connectivity=True):
    world, land, resource = (snapshot[k] for k in ('world', 'landscape', 'resources'))
    width, height = resource['w'], resource['h']
    size = width * height
    require((width, height) == (profile['width'], profile['height']), '地图尺寸与方案不符')
    require((world['width'], world['height']) == (width, height) == (land['width'], land['height']), '前后端尺寸不一致')
    require(world.get('topologyVersion') == land.get('topologyVersion'), '地形版本不一致')
    legacy = world.get('version') == 1 and 'regionRows' not in world
    require(legacy or 'spawnZones' not in world, '静态地图不能包含玩家出生分配')
    ids = decode_regions(world)
    cells = resource['list']
    require(len(cells) == size, '资源格子数量错误')
    water = cell_set(land['riverCells'], size, '河流')
    mountain = cell_set(land['mountainCells'], size, '山脉')
    bridge_water = cell_set(land.get('bridgeWaterCells', []), size, '桥下水面')
    empty = cell_set(resource['emptyCells'], size, '空地')
    blocked = water | mountain
    require(not water & mountain and not blocked & bridge_water and not empty & blocked, '空地、水面或阻挡相互冲突')
    reserved, landmarks = set(), set()
    city_ids = set()
    for c in world['cities']:
        require(city_key(c) not in city_ids, '城池 ID 重复')
        city_ids.add(city_key(c))
        x, y, radius = c['x'], c['y'], c['footprintRadius']
        require(0 <= x - radius <= x + radius < width and 0 <= y - radius <= y + radius < height, '城池占地越界')
        require(ids[y * width + x] == c['region'], '城池所属州错误')
        for cy in range(y - radius, y + radius + 1):
            for cx in range(x - radius, x + radius + 1):
                i = cy * width + cx
                require(i not in reserved and i not in blocked and i not in empty, '城池占地冲突')
                require(cells[i] == ([51, c['level']] if (cx, cy) == (x, y) else [0, 0]), '资源侵入城池占地')
                reserved.add(i)
        landmarks.add(y * width + x)
    gates, gate_ids = set(), set()
    graph = {r['id']: set() for r in world['regions']}
    for gate in world['gates']:
        x, y = gate['x'], gate['y']
        require(0 <= x < width and 0 <= y < height and gate['id'] not in gate_ids, '关口坐标或 ID 无效')
        i = y * width + x
        require(i not in landmarks and i not in blocked, '关口重叠或被阻挡')
        require(cells[i] == [50, gate['level']], '关口资源索引错误')
        require(len(gate['regions']) == 2, '关口必须连接两个州')
        a, b = gate['regions']
        require(a in graph and b in graph and a != b, '关口连接州错误')
        graph[a].add(b); graph[b].add(a)
        gate_ids.add(gate['id']); gates.add(i); landmarks.add(i)
        if gate.get('crossing') == 'bridge':
            require(gate['axis'] in ('x', 'y'), '桥梁轴向错误')
            radius = gate['bridgeSpan'] // 2 + 3
            for u in range(-radius, radius + 1):
                for v in range(-2, 3):
                    cx, cy = (x + u, y + v) if gate['axis'] == 'x' else (x + v, y + u)
                    require(0 <= cx < width and 0 <= cy < height, '桥梁引道越界')
                    j = cy * width + cx
                    if j not in blocked and j != i:
                        require(j in empty and cells[j] == [0, 0], '资源侵入桥面或引道')
    reached, queue = set(), [next(iter(graph))]
    while queue:
        rid = queue.pop()
        if rid not in reached:
            reached.add(rid); queue.extend(graph[rid] - reached)
    require(reached == set(graph), '州域交通图断开，无法夺取天下')

    fixed_ids, fixed_names = set(), set()
    forbidden_fixed = blocked | reserved | empty | gates
    for name, table in sorted(snapshot['fixed'].items()):
        buckets = defaultdict(list)
        for p in table['points']:
            x, y = p['x'], p['y']
            require(type(x) is int and type(y) is int and 0 <= x < width and 0 <= y < height, '固定资源越界')
            i = y * width + x
            require(i not in fixed_ids and p['id'] not in fixed_names, '固定资源 ID 或坐标重复')
            require(ids[i] == p['region'] and cells[i] == [p['type'], p['level']], '固定资源被移动或改写')
            require(i not in forbidden_fixed, '固定资源占用禁用位置')
            bx, by = x // 64, y // 64
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for q in buckets[bx + dx, by + dy]:
                        low = min(p['level'], q['level'])
                        spacing = (table['level6MinDistance'] if low >= 6 else table['advancedMinDistance'] if low >= 5 else table['minDistance']) if name == 'birth' else min(int(table['spacing'][str(p['region'])].get(str(low), 12)), int(table['spacing'][str(q['region'])].get(str(low), 12)))
                        require((x - q['x']) ** 2 + (y - q['y']) ** 2 >= spacing ** 2, '固定资源间距不足')
            buckets[bx, by].append(p)
            fixed_ids.add(i); fixed_names.add(p['id'])

    counts = {rid: Counter() for rid in graph}
    usable = Counter()
    for i, cell in enumerate(cells):
        require(isinstance(cell, list) and len(cell) == 2 and all(type(v) is int for v in cell), '资源单元格式错误')
        kind, level = cell
        require(kind in (0, 50, 51, *RESOURCE_TYPES), '未知地图类型')
        if i not in blocked:
            usable[ids[i]] += 1
        if kind in RESOURCE_TYPES:
            require(1 <= level <= 10 and i not in blocked and i not in empty and i not in reserved, '资源等级或位置无效')
            counts[ids[i]][f'{kind}:{level}'] += 1
            if i not in fixed_ids:
                allowed = (1, 2, 3) if ids[i] < 6 else (2, 3, 4, 5) if ids[i] < 9 else (3, 4, 5, 6)
                require(level in allowed, '普通资源超过州域等级上限')
            x, y = i % width, i // width
            for dx, dy in DIRECTIONS:
                if 0 <= x + 2 * dx < width and y + 2 * dy < height:
                    a, b = cells[(y + dy) * width + x + dx], cells[(y + 2 * dy) * width + x + 2 * dx]
                    if a[0] in RESOURCE_TYPES and b[0] in RESOURCE_TYPES:
                        require(not (kind == a[0] == b[0]) and not (level == a[1] == b[1]), f'资源三连: {x},{y}')
        elif kind == 0:
            require(level == 0 and (i in blocked or i in empty or i in reserved), '空白格缺少通行分类')
        else:
            require(i in landmarks, '未登记的城池或关口')
    require(all(cells[i] == [0, 0] for i in blocked | empty), '阻挡或空地存在资源')
    density = {r: sum(counts[r].values()) / usable[r] for r in graph if r < 6}
    ratio = max(density.values()) / min(density.values()) if density else 1
    require(ratio <= profile.get('maxBirthDensityRatio', 1.25), '出生州资源密度差距过大')
    if connectivity and not legacy:
        validate_connectivity(world, ids, blocked | gates)
    report = {'width': width, 'height': height, 'cells': size, 'regions': len(graph), 'cities': len(city_ids),
              'gates': len(gates), 'blocked': len(blocked), 'empty': len(empty), 'fixedResources': len(fixed_ids),
              'birthDensityRatio': round(ratio, 6), 'resourcesByRegion': {str(r): dict(sorted(c.items())) for r, c in counts.items()},
              'checks': ['coordinates', 'fixed-resources', 'resource-runs', 'city-footprints', 'bridge-approaches', 'region-graph', 'birth-density']}
    if connectivity and not legacy:
        report['checks'].append('eight-direction-gate-isolation')
    if legacy:
        report['checks'].append('legacy-client-v1-region-compatibility')
    return report


def validate_connectivity(world, ids, closed):
    width, height = world['width'], world['height']
    size = width * height
    labels = array('i', [-1]) * size
    for i in closed:
        labels[i] = -2
    region_components = {}
    for region in world['regions']:
        start = region['y'] * width + region['x']
        require(labels[start] == -1, '州域中心被阻挡，或存在绕关通路')
        label = region['id']
        region_components[label] = start
        labels[start] = label
        queue = deque([start])
        while queue:
            i = queue.popleft()
            require(ids[i] == label, '实际可行走区域与州域标记不一致')
            x, y = i % width, i // width
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    cx, cy = x + dx, y + dy
                    if 0 <= cx < width and 0 <= cy < height:
                        j = cy * width + cx
                        if labels[j] == -1:
                            labels[j] = label; queue.append(j)
    require(-1 not in labels, '存在无法从州府抵达的孤立地块')
    for gate in world['gates']:
        x, y = gate['x'], gate['y']
        adjacent = {labels[(y + dy) * width + x + dx] for dy in (-1, 0, 1) for dx in (-1, 0, 1)
                    if 0 <= x + dx < width and 0 <= y + dy < height}
        require(adjacent - {-2} == set(gate['regions']), '关门未连接指定两州: ' + gate['name'])


def lua_value(value):
    if value is None:
        return 'nil'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') + '"'
    if isinstance(value, list):
        return '{' + ','.join(lua_value(v) for v in value) + '}'
    if isinstance(value, dict):
        return '{\n' + ',\n'.join('[' + lua_value(k) + ']=' + lua_value(value[k]) for k in sorted(value)) + '\n}'
    raise TypeError(type(value))


def lua_module(value):
    return ('-- 原样导出客户端固定地图；通过版本校验后加载。\nreturn ' + lua_value(value) + '\n').encode('utf8')


def terrain_snapshot(snapshot):
    world, land, resource = (snapshot[k] for k in ('world', 'landscape', 'resources'))
    width = resource['w']
    reserved = sorted({y * width + x for c in world['cities']
                       for y in range(c['y'] - c['footprintRadius'], c['y'] + c['footprintRadius'] + 1)
                       for x in range(c['x'] - c['footprintRadius'], c['x'] + c['footprintRadius'] + 1)})
    terrain = {k: land[k] for k in ('width', 'height', 'riverCells', 'mountainCells')}
    terrain.update(blockedCells=sorted(set(land['riverCells']) | set(land['mountainCells'])), reservedCityCells=reserved)
    return terrain


def server_files(snapshot):
    world, resource = snapshot['world'], snapshot['resources']
    width = resource['w']
    terrain = terrain_snapshot(snapshot)
    # cellId 从 0 起，必须输出显式键，不能让 Lua 数组向后错一格。
    entries = ',\n'.join('[' + str(i) + ']={' + str(p[0]) + ',' + str(p[1]) + '}' for i, p in enumerate(resource['list']))
    map_lua = ('-- cellId=y*width+x，从0起；不要使用 #list。\nreturn {w=' + str(width) + ',h=' + str(resource['h']) + ',list={\n' + entries + '\n},emptyCells=' + lua_value(resource['emptyCells']) + '}\n').encode('utf8')
    return {'server/mapRes_0.lua': map_lua, 'server/campaign-map.lua': lua_module(world), 'server/terrain.lua': lua_module(terrain)}


def tmx_bytes(snapshot):
    world, land = snapshot['world'], snapshot['landscape']
    width, height = world['width'], world['height']
    blocked = set(land['riverCells']) | set(land['mountainCells'])
    cities = {c['y'] * width + c['x'] for c in world['cities']}
    layers = ''.join(f'<layer id="{number}" name="{name}" width="{width}" height="{height}" visible="0"><data encoding="csv">' + ','.join('1' if i in indices else '0' for i in range(width * height)) + '</data></layer>' for number, (name, indices) in enumerate((('obstruct', blocked), ('city_position', cities)), 1))
    return (f'<?xml version="1.0" encoding="UTF-8"?>\n<map version="1.4" tiledversion="1.4.3" orientation="isometric" renderorder="right-down" width="{width}" height="{height}" tilewidth="200" tileheight="100" infinite="0" nextlayerid="3" nextobjectid="1"><tileset firstgid="1" source="original-ground.tsx"/>' + layers + '</map>\n').encode('utf8')


def validate_tmx(data, snapshot):
    """检查客户端实际使用的 TMX；不重建或悄悄修正客户端图层。"""
    root = ET.fromstring(data)
    width, height = snapshot['resources']['w'], snapshot['resources']['h']
    require((int(root.attrib['width']), int(root.attrib['height'])) == (width, height), '客户端 TMX 尺寸不一致')
    masks = {'obstruct': set(snapshot['landscape']['riverCells']) | set(snapshot['landscape']['mountainCells']),
             'city_position': {c['y'] * width + c['x'] for c in snapshot['world']['cities']}}
    for name, expected in masks.items():
        layers = root.findall(f"layer[@name='{name}']")
        require(len(layers) == 1, '客户端 TMX 图层缺失或重复: ' + name)
        layer = layers[0]
        require((int(layer.attrib['width']), int(layer.attrib['height'])) == (width, height), '客户端 TMX 图层尺寸不一致')
        values = layer.find('data')
        require(values is not None and values.attrib.get('encoding') == 'csv', '客户端 TMX 图层不是 CSV')
        indices, count = set(), 0
        for i, raw in enumerate(values.text.strip().split(',')):
            value = int(raw.strip())
            require(value in (0, 1), '客户端 TMX 逻辑层存在未知值')
            if value:
                indices.add(i)
            count += 1
        require(count == width * height and indices == expected, '客户端 TMX 与地形/城池数据不一致: ' + name)


def snapshot_diff(before, after):
    require((before['resources']['w'], before['resources']['h']) == (after['resources']['w'], after['resources']['h']), '差异比较需要相同尺寸')
    width = after['resources']['w']
    changed, examples = 0, []
    for i, (a, b) in enumerate(zip(before['resources']['list'], after['resources']['list'])):
        if a != b:
            changed += 1
            if len(examples) < 30:
                examples.append({'x': i % width, 'y': i // width, 'from': a, 'to': b})
    result = {'changedCells': changed, 'examples': examples}
    for name in ('cities', 'gates'):
        key = city_key if name == 'cities' else lambda p: p['id']
        a = {key(p): p for p in before['world'][name]}
        b = {key(p): p for p in after['world'][name]}
        result[name] = {'added': sorted(b.keys() - a.keys()), 'removed': sorted(a.keys() - b.keys()),
                        'changed': [k for k in sorted(a.keys() & b.keys()) if a[k] != b[k]]}
    for key in ('riverCells', 'mountainCells'):
        a, b = set(before['landscape'][key]), set(after['landscape'][key])
        result[key] = {'added': len(b - a), 'removed': len(a - b)}
    result['regionRowsChanged'] = before['world'].get('regionRows') != after['world'].get('regionRows')
    return result


def png_rgb(width, height, rows):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    raw = b''.join(b'\0' + row for row in rows)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')


def preview_files(snapshot, report, revision):
    world, land, resource = (snapshot[k] for k in ('world', 'landscape', 'resources'))
    width, height = resource['w'], resource['h']
    ids = decode_regions(world)
    colors = {r['id']: bytes.fromhex(r['color'].lstrip('#')) for r in world['regions']}
    water, mountain = set(land['riverCells']), set(land['mountainCells'])
    blocked = water | mountain
    rows, resource_rows = [], []
    palette = {52: (55, 122, 76), 53: (107, 108, 120), 54: (177, 165, 144), 55: (209, 164, 48)}
    for y in range(height):
        row, rrow = bytearray(), bytearray()
        for x in range(width):
            i = y * width + x
            kind, level = resource['list'][i]
            color = b'\x4c\x83\x9c' if i in water else b'\x4b\x50\x43' if i in mountain else colors[ids[i]]
            row.extend(color)
            rrow.extend(bytes(palette[kind]) if kind in palette else color if i in blocked else b'\x23\x2a\x25')
        rows.append(bytes(row)); resource_rows.append(bytes(rrow))
    marks = []
    for c in world['cities']:
        label = html.escape(c['name'])
        marks.append(f'<circle cx="{c["x"]}" cy="{c["y"]}" r="5" fill="#fff1bd"/><text x="{c["x"]}" y="{c["y"] - 10}" text-anchor="middle">{label}</text>')
    for g in world['gates']:
        marks.append(f'<rect x="{g["x"]-3}" y="{g["y"]-3}" width="6" height="6" fill="#d65d45"/>')
    text = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>地图构建预览</title>
<style>body{{background:#17221e;color:#e8dfc9;font:16px sans-serif;max-width:1100px;margin:24px auto}}svg,img{{width:100%;height:auto}}text{{font-size:14px;fill:#fff;paint-order:stroke;stroke:#17221e;stroke-width:3px}}pre{{white-space:pre-wrap}}a{{color:#e4bc77}}</style>
<h1>{html.escape(world['title'])}</h1><p>地图版本 {revision[:16]} · 来源：客户端已确认地图</p>
<p>技术预览：州域底色、山脉深灰、河流蓝色、城池浅金、关口红色。美术效果以客户端预览为准。</p>
<svg viewBox="0 0 {width} {height}"><image href="preview.png" width="{width}" height="{height}"/>{''.join(marks)}</svg>
<h2>资源分布</h2><p>绿色：木；灰色：铁；浅褐：石；金色：粮。</p><img src="resources.png" alt="资源分布图">
<p><a href="report.json">校验报告</a> · <a href="diff.json">与客户端源图比较</a> · <a href="manifest.json">版本清单</a></p>
<pre>{html.escape(json.dumps(report, ensure_ascii=False, indent=2))}</pre></html>'''
    return {'preview.png': png_rgb(width, height, rows), 'resources.png': png_rgb(width, height, resource_rows), 'preview.html': text.encode('utf8')}
