"""只读取指定 Git 提交中的地图文件，不创建/修改客户端工作区。"""
from contextlib import contextmanager
import io
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
from urllib.parse import urlsplit


@contextmanager
def fetch_source(repository, ref, paths):
    if not repository or repository.startswith('-') or not ref or ref.startswith('-'):
        raise ValueError('需要有效的 CLIENT_REPO 和 CLIENT_REF')
    if repository.startswith(('http://', 'https://')) and urlsplit(repository).username:
        raise ValueError('仓库地址不能包含凭据，请使用 Git credential helper 或 SSH')
    environment = os.environ.copy()
    environment['GIT_TERMINAL_PROMPT'] = '0'
    environment.setdefault('GIT_SSH_COMMAND', 'ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes')
    with tempfile.TemporaryDirectory(prefix='slg-map-source-') as temporary:
        root = Path(temporary)
        repo = root / 'repository.git'
        checkout = root / 'snapshot'

        def git(*args, input=None):
            process = subprocess.Popen(['git', *args], env=environment, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                stdout, stderr = process.communicate(input=input, timeout=180)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                raise ValueError('拉取客户端 Git 地图超时；未使用缓存或本地工作区替代')
            if process.returncode:
                raise ValueError('拉取客户端 Git 地图失败: ' + stderr.decode('utf8', errors='replace').strip())
            return stdout

        git('init', '--bare', str(repo))
        git('--git-dir', str(repo), 'remote', 'add', 'origin', repository)
        git('--git-dir', str(repo), 'config', 'remote.origin.promisor', 'true')
        git('--git-dir', str(repo), 'config', 'remote.origin.partialclonefilter', 'blob:none')
        # 仅拉取提交与所需 blob，避免下载全部游戏美术资源。
        git('--git-dir', str(repo), 'fetch', '--depth=1', '--filter=blob:none', '--no-tags', 'origin', ref)
        commit = git('--git-dir', str(repo), 'rev-parse', 'FETCH_HEAD^{commit}').decode().strip()
        if not re.fullmatch(r'[0-9a-f]{40,64}', commit):
            raise ValueError('Git 提交号无效')
        # archive 在部分 Git 版本会预取整棵树的 blob；显式只抓所需对象。
        listing = git('--git-dir', str(repo), 'ls-tree', '-r', '-z', commit, '--', *paths)
        objects = {}
        for entry in listing.split(b'\0'):
            if not entry:
                continue
            meta, name = entry.split(b'\t', 1)
            mode, kind, oid = meta.decode().split()
            name = name.decode('utf8')
            if name not in paths or kind != 'blob' or mode not in ('100644', '100755'):
                raise ValueError('Git 地图源不是普通文件: ' + name)
            objects[name] = oid
        if set(objects) != set(paths):
            raise ValueError('Git 提交缺少地图文件: ' + ', '.join(sorted(set(paths) - set(objects))))
        names = sorted(objects)
        requested = ('\n'.join(objects[name] for name in names) + '\n').encode('ascii')
        git('--git-dir', str(repo), '-c', 'fetch.negotiationAlgorithm=noop', 'fetch', 'origin',
            '--no-tags', '--no-write-fetch-head', '--recurse-submodules=no', '--filter=blob:none', '--stdin', input=requested)
        stream = io.BytesIO(git('--git-dir', str(repo), 'cat-file', '--batch', input=requested))
        for name in names:
            header = stream.readline().decode('ascii').strip().split()
            if len(header) != 3 or header[:2] != [objects[name], 'blob']:
                raise ValueError('Git 地图对象读取失败: ' + name)
            size = int(header[2])
            data = stream.read(size)
            if len(data) != size or stream.read(1) != b'\n':
                raise ValueError('Git 地图对象内容不完整: ' + name)
            if Path(name).is_absolute() or '..' in Path(name).parts:
                raise ValueError('Git 地图文件路径越界')
            target = checkout / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        yield checkout, {'repository': repository, 'requestedRef': ref, 'commit': commit}
