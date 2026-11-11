#!/usr/bin/env python3
"""Reproducible, exact-build Diablo III native macOS bring-up."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'third_party/nxnative'
WORK = ROOT / 'work'
TITLE = '01001B300B9BE000'
COMMIT = '9579030e5b1f0443c12b7376559560915b6d4c4b'
PROFILE = ROOT / 'config/diablo3-2.7.7.json'
SUFFIXES = ('patched.bin', 'fixups.tsv', 'gates.tsv', 'sites.tsv', 'cuts.tsv', 'obs.tsv', 'params.tsv')


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')
    tmp.replace(path)


def env():
    result = {k: v for k, v in os.environ.items() if not k.startswith('DM_')}
    result.update(DM_ROOT=str(WORK), DM_GAME=TITLE, DM_RULESET='native', DM_PRIVATE_GATES='0')
    dotnet = shutil.which('dotnet')
    if dotnet:
        result['DOTNET_ROOT'] = str(Path(dotnet).resolve().parent)
    return result


def run(command, log, extra=None, cwd=None, timeout=None):
    log.parent.mkdir(parents=True, exist_ok=True)
    print(f'{log.relative_to(ROOT)}', flush=True)
    with log.open('w') as output:
        status = subprocess.run([str(x) for x in command], cwd=cwd, env=env() | (extra or {}),
                                stdout=output, stderr=subprocess.STDOUT, timeout=timeout).returncode
    if status:
        raise RuntimeError(f'Command exited {status}; inspect {log}')


def profile():
    return json.loads(PROFILE.read_text())


def check_modules(exefs=None):
    directory = exefs or WORK / 'game/ExeFS'
    for name, expected in profile()['modules'].items():
        source = directory / name
        with source.open('rb') as stream:
            header = stream.read(256)
        if header[:4] != b'NSO0' or header[0x40:0x60].hex() != expected['build_id'] or sha(source) != expected['sha256']:
            raise ValueError(f'{name}: exact Build ID/SHA mismatch; survey the new build first')


def fingerprints():
    return {f'{n}.{s}': sha(WORK / 'rewrite' / f'{n}.{s}')
            for n in profile()['runtime_modules'] for s in SUFFIXES}


def native_fingerprints():
    return {name:sha(ROOT/'native'/name) for name in ('gamepad_mac.m','controller_effects.m','controller_effects.h','lan_discovery_apple.m')}


def copy_native():
    for name in native_fingerprints():shutil.copyfile(ROOT/'native'/name,UPSTREAM/'dm/host'/name)


def upstream_head():
    return subprocess.run(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()


def bootstrap(_):
    if not UPSTREAM.exists():
        cloned = False
        if shutil.which('git'):
            try:
                run(['git', 'clone', 'https://github.com/seedds/nxnative.git', UPSTREAM], WORK / 'logs/clone.log')
                run(['git', 'checkout', COMMIT], WORK / 'logs/checkout.log', cwd=UPSTREAM)
                cloned = upstream_head() == COMMIT
            except Exception:
                cloned = False
        if not cloned:
            # 上游把 9579030e force-push 丢了（孤儿提交）：clone / fetch 拿不到，tarball 端点会静默回退成默认分支的内容（实测）。
            # git trees API 却按 SHA 返回这棵树的真 blob 清单；其中大多数文件与默认分支一致（内容哈希相同），
            # 所以：浅克隆默认分支当底 → trees API 逐路径比对 blob SHA → 只有对不上的少数文件走 contents API（ref=孤儿 SHA，实测能拿到真对象）取回。
            # Upstream force-pushed 9579030e away (an orphan commit): clone/fetch cannot get it, and the tarball endpoint silently serves
            # the default branch instead (measured). The git trees API still lists the orphan tree's true blob SHAs; most files hash the
            # same as the default branch, so: shallow-clone the default branch as the base, compare per-path blob SHAs against the trees
            # API, and fetch only the differing files through the contents API (ref=<orphan SHA>), which serves the real objects.
            import base64
            import json
            import stat
            import urllib.request

            def _force_remove(func, path, _exc):
                try: os.chmod(path, stat.S_IWRITE)
                except OSError: pass
                func(path)
            shutil.rmtree(UPSTREAM, ignore_errors=False, onerror=_force_remove)
            UPSTREAM.parent.mkdir(parents=True, exist_ok=True)
            run(['git', 'clone', '--depth', '1', 'https://github.com/seedds/nxnative.git', UPSTREAM], WORK / 'logs/clone-default.log')
            token = os.environ.get('GITHUB_TOKEN') or subprocess.run(['gh', 'auth', 'token'], capture_output=True, text=True).stdout.strip()
            if not token:
                raise ValueError('需要 GITHUB_TOKEN 或 gh 登录：上游孤儿提交只能经 GitHub API 重建')

            def api(path):
                req = urllib.request.Request('https://api.github.com' + path, headers={'Authorization': f'Bearer {token}', 'User-Agent': 'dr3-bootstrap'})
                import time as _time
                for attempt in range(4):   # GitHub API 偶发 5xx/断流：退避重试，别让一次抖动毁掉整次构建 | GitHub API throws sporadic 5xx: back off and retry so one hiccup does not kill the build
                    try:
                        with urllib.request.urlopen(req, timeout=120) as resp:
                            return json.loads(resp.read())
                    except urllib.error.HTTPError as err:
                        # 403 = 次级限流/滥用风控（大树递归查询连跑易触发）：也要长退避重试，别让一次窗口期毁掉整次构建
                        if (err.code < 500 and err.code != 429 and err.code != 403) or attempt == 3: raise
                        _time.sleep(2 ** attempt * 15)   # 15/30/60/120s：403 是分钟级窗口，短退避没用
                    except (urllib.error.URLError, TimeoutError, ConnectionError) as err:
                        if attempt == 3: raise
                        _time.sleep(2 ** attempt * 2)
                raise RuntimeError('unreachable')

            tree = api(f'/repos/seedds/nxnative/git/trees/{COMMIT}?recursive=1')
            if tree.get('truncated'):
                raise ValueError('上游树过大，trees API 截断了；换别的办法重建')
            local = {}
            for line in subprocess.check_output(['git', '-C', str(UPSTREAM), 'ls-tree', '-r', 'HEAD'], text=True).splitlines():
                meta, path = line.split('\t', 1)
                mode, kind, sha_ = meta.split()
                local[path] = (mode, kind, sha_)
            fetched = 0
            for entry in tree['tree']:
                path = UPSTREAM / entry['path']
                if entry['type'] != 'blob':
                    continue   # 子模块（commit）与本仓库无关；目录自动存在
                want = entry['sha']
                have = local.get(entry['path'])
                if have and have[2] == want:
                    continue   # 与默认分支逐字节相同：保留浅克隆的文件
                if have is None:
                    path.parent.mkdir(parents=True, exist_ok=True)
                elif path.exists() and not have[1] == 'blob':
                    die(f'上游孤儿树里 {entry["path"]} 的类型变了，不再自动处理')
                blob = api(f'/repos/seedds/nxnative/git/blobs/{want}')
                data = base64.b64decode(blob['content'])
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                fetched += 1
            orphan_paths = {e['path'] for e in tree['tree'] if e['type'] == 'blob'}
            for path_str in local.keys() - orphan_paths:
                (UPSTREAM / path_str).unlink(missing_ok=True)   # 孤儿树里已删除的文件
            print(f'上游孤儿提交重建：{len(tree["tree"])} 项，从 API 取回 {fetched} 个文件', flush=True)
            run(['git', 'init', '-q'], WORK / 'logs/upstream-init.log', cwd=UPSTREAM)
            run(['git', 'config', 'core.autocrlf', 'false'], WORK / 'logs/upstream-config.log', cwd=UPSTREAM)   # 不转换换行：上游树与补丁产物保持字节原样（Windows 的 CRLF 会污染链版本输入） | no newline conversion: the tree and patch results stay byte-exact (Windows CRLF would pollute chain-version inputs)
            run(['git', 'add', '-A'], WORK / 'logs/upstream-add.log', cwd=UPSTREAM)
            run(['git', '-c', 'user.name=dr3-bootstrap', '-c', 'user.email=bootstrap@local',
                 'commit', '-qm', f'nxnative pinned snapshot {COMMIT[:12]}'], WORK / 'logs/upstream-commit.log', cwd=UPSTREAM)
            (UPSTREAM / '.dm-pinned').write_text(COMMIT + '\n')
    actual = upstream_head()
    if actual != COMMIT:
        pinned = (UPSTREAM / '.dm-pinned')
        # 快照 zip（Release 资产）解压的树没有 .git：pinned 标记对上 COMMIT 即认（CI 免 API 重建的主力路径）
        # | A snapshot-zip tree has no .git: accept the .dm-pinned marker alone when it matches COMMIT.
        if not (pinned.exists() and pinned.read_text().strip() == COMMIT and (actual or not (UPSTREAM / '.git').exists())):
            raise ValueError(f'Upstream commit mismatch (HEAD={actual or "none"}); use the pinned clean checkout')
    patch = ROOT / 'patches/nxnative.patch'
    # 「补丁已应用」判据 = 产物文件在不在（lan_native.h 是补丁新增文件，基线 zip 没有）。
    # 不能用 git apply --reverse --check：快照树无 .git 时 git 2.56 在非仓库目录静默无效且退出 0
    # （e1d9ae5 实证），CI 上曾误判"已应用"跳过应用 → 头文件缺失编译挂（43026386771）。
    applied = (UPSTREAM / 'dm/host/lan_native.h').exists()
    if not applied:
        if (UPSTREAM / '.git').exists():
            run(['git', 'apply', '--check', patch], WORK / 'logs/patch-check.log', cwd=UPSTREAM)
            run(['git', 'apply', patch], WORK / 'logs/patch.log', cwd=UPSTREAM)
        else:   # 快照树无 .git：直接 GNU/POSIX patch（macOS 自带 patch 支持 -p1 -i）
            run(['patch', '-p1', '-i', str(patch.resolve())], WORK / 'logs/patch-p1.log', cwd=UPSTREAM)
        if not (UPSTREAM / 'dm/host/lan_native.h').exists():   # 落地校验（677a621 先例）
            sys.exit('[x] 补丁应用后 dm/host/lan_native.h 仍缺失：apply 全路径失效')
    copy_native()
    game = UPSTREAM / 'dm/games' / TITLE
    game.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'config' / TITLE / 'game.tsv', game / 'game.tsv')
    run([sys.executable, UPSTREAM / 'dm/games/game.py', 'header', TITLE,
         UPSTREAM / 'dm/host/gen' / TITLE / 'game_profile.h'],
        WORK / 'logs/game-profile.log')
    for name in ('shader_facts.tsv', 'shader_map.tsv', 'shader_map.tsv.conflicts.tsv', 'shader_pairs.tsv',
                 'pso_manifest.tsv', 'bf_want.tsv', 'c1_full.tsv'):
        if not (game / name).exists():
            (game / name).write_text('# D3 inventory pending; no graphics validation\n', newline='\n')   # 钉死 LF：内容参与链版本，Windows 文本模式会转 CRLF | pin LF: the content feeds the chain version; Windows text mode would turn it CRLF
    target = UPSTREAM / 'dm/verify'
    target.mkdir(exist_ok=True)
    for path in (ROOT / 'third_party/d2r-verify').glob('*.py'):
        shutil.copyfile(path, target / path.name)
    run([sys.executable, UPSTREAM / 'dm/gfx/tools/dmsh_chain.py', '--header'], WORK / 'logs/chain.log')


def prepare(args):
    final = WORK / 'game'
    if final.exists():
        check_modules()
        print('Exact game build already prepared')
        return
    stage = WORK / 'game.partial'
    if stage.exists():
        raise ValueError('Incomplete game.partial exists; preserve it and select a clean extraction destination')
    tool = WORK / 'tools/nx_extract'
    run(['dotnet', 'publish', UPSTREAM / 'dm/tools/nx_extract', '-c', 'Release', '-o', tool], WORK / 'logs/build-extractor.log')
    run([tool / 'nx_extract', args.keys.resolve(strict=True), args.base.resolve(strict=True),
         args.update.resolve(strict=True), stage], WORK / 'logs/extract.log')
    check_modules(stage / 'ExeFS')
    marker = stage / 'RomFS' / profile()['romfs_marker']
    if not marker.is_file():
        raise ValueError('Missing RomFS marker')
    files = [{'path': str(p.relative_to(stage / 'RomFS')), 'bytes': p.stat().st_size, 'sha256': sha(p)}
             for p in sorted((stage / 'RomFS').rglob('*')) if p.is_file()]
    save(stage / 'inventory.json', {'files': files, 'bytes': sum(x['bytes'] for x in files),
                                   'base_sha256': sha(args.base), 'update_sha256': sha(args.update)})
    stage.rename(final)


def rewrite(_):
    check_modules()
    output = WORK / 'rewrite'
    output.mkdir(exist_ok=True)
    for name in profile()['runtime_modules']:
        run([sys.executable, UPSTREAM / 'dm/tools/patch_nso.py', WORK / 'game/ExeFS' / name, output, name],
            WORK / 'logs' / f'rewrite-{name}.log')


def verify(_):
    check_modules()
    results = {}
    for name in profile()['runtime_modules']:
        for script, options in [('structck.py', []), ('equiv.py', ['--jobs', '4', '--seed', '1', '--mutate', '100'])]:
            log = WORK / 'logs' / f'verify-{name}-{script}.log'
            run([sys.executable, UPSTREAM / 'dm/verify' / script, WORK / 'rewrite', name,
                 WORK / 'game/ExeFS' / name, *options], log, {'LLVM_BIN': '/opt/homebrew/opt/llvm/bin'})
            results[f'{name}/{script}'] = log.read_text().splitlines()[-1]
    save(WORK / 'verification.json', {'passed': True, 'artifacts': fingerprints(), 'results': results,
         'profile_sha256': sha(PROFILE), 'limitations': ['Exclusives replaced in both Unicorn inputs; concurrency unproven.',
         'CTR_EL0 changes cache-line policy; structurally checked as an intentional adaptation.', 'Does not establish gameplay compatibility.']})


def shader_chain():
    header = (UPSTREAM / 'dm/games' / TITLE / 'dmsh_chain.h').read_text()
    return re.search(r'#define DMSH_CHAIN "([0-9a-f]{12})"', header).group(1)


def check_shaders():
    directory = WORK / 'build/cache/metal_shader_cache' / ('b-' + shader_chain())
    result = json.loads((directory / '_b_build.json').read_text())
    if not result or any(row['st'] != 'ok' for row in result):
        raise ValueError('Complete shader compilation required; inspect build-shaders.log')
    for row in result:
        if not (directory / (row['key'] + '_b.metallib')).is_file():
            raise ValueError('Shader library missing: ' + row['key'])
    return directory


def shaders(_):
    check_modules()
    run([sys.executable, ROOT / 'tools/cpk_shaders.py'], WORK / 'logs/cpk-shaders.log')
    run([sys.executable, ROOT / 'tools/shader_packages.py'], WORK / 'logs/shader-packages.log')
    run([sys.executable, UPSTREAM / 'dm/gfx/tools/dmsh_chain.py', '--update-lock'], WORK / 'logs/shader-lock.log')
    run([sys.executable, UPSTREAM / 'dm/gfx/tools/dmsh_chain.py', '--header'], WORK / 'logs/chain.log')
    run([sys.executable, UPSTREAM / 'dm/gfx/tools/dmsh_build.py', WORK / 'shaders/package',
         WORK / 'build/cache/metal_shader_cache'], WORK / 'logs/build-shaders.log', {'J': '6'})
    directory = check_shaders()
    run([sys.executable, UPSTREAM / 'dm/gfx/tools/c1_guard.py', directory,
         UPSTREAM / 'dm/games' / TITLE / 'c1_full.tsv'], WORK / 'logs/c1-guard.log')


def build(_):
    copy_native()
    run(['make', '-C', UPSTREAM / 'dm/host', f'GAME={TITLE}', '-j6'], WORK / 'logs/build-mac.log')
    save(WORK / 'host-build.json', {'binary_sha256': sha(UPSTREAM / 'dm/host/dmhost'), 'upstream': COMMIT,
                                  'profile_sha256': sha(ROOT / 'config' / TITLE / 'game.tsv'),
                                  'shader_chain': shader_chain(),
                                  'patch_sha256': sha(ROOT / 'patches/nxnative.patch'),
                                  'gamepad_sha256': sha(ROOT / 'native/gamepad_mac.m'), 'native_files':native_fingerprints()})


def launch(args):
    check_modules()
    verified = json.loads((WORK / 'verification.json').read_text())
    if not verified.get('passed') or verified['artifacts'] != fingerprints() or verified['profile_sha256'] != sha(PROFILE):
        raise ValueError('Rewritten images changed or verification incomplete; run verify')
    binary = UPSTREAM / 'dm/host/dmhost'
    built = json.loads((WORK / 'host-build.json').read_text())
    if (built['binary_sha256'] != sha(binary)
            or built['patch_sha256'] != sha(ROOT / 'patches/nxnative.patch')
            or built.get('gamepad_sha256') != sha(ROOT / 'native/gamepad_mac.m')
            or built.get('native_files') != native_fingerprints()
            or built['profile_sha256'] != sha(ROOT / 'config' / TITLE / 'game.tsv')):
        raise ValueError('Host changed; rebuild before running')
    if built.get('shader_chain') != shader_chain():
        raise ValueError('Shader chain changed; rebuild the host')
    if not args.capture_shaders:
        check_shaders()
    stamp = time.strftime('%Y%m%d-%H%M%S') + '-' + str(os.getpid())
    directory = WORK / 'run' / stamp
    directory.mkdir(parents=True)
    for name in ('save', 'temp', 'shdump', 'shaders'):
        (WORK / 'run' / name).mkdir(exist_ok=True)
    settings = dict(DM_ROMFS=str(WORK / 'game/RomFS'), DM_SAVE=str(WORK / 'run/save'),
                    DM_TEMP=str(WORK / 'run/temp'), DM_WINDOW='1', DM_DBG='1', DM_AUDIO='1',
                    DM_LANG='zh-Hans', DM_AOC_DIR=str(WORK / 'aoc'), MTL_HUD_ENABLED='1',
                    DM_NVN_SHMAP=str(UPSTREAM / 'dm/games' / TITLE / 'shader_map.tsv'),
                    DM_MSL_DIR=str(WORK / 'build/cache/metal_shader_cache'), DM_PSO_MANIFEST='off', DM_NVN_TBDR='0',
                    DM_NVN_UNIFORM_FORWARD='1',
                    DM_HID_RECEIPT_LOG=str(directory / 'controller.jsonl'), DM_HID_RECEIPT_LIMIT='65536',
                    DM_PAD_EVENT_LOG=str(directory / 'controller-events.jsonl'),
                    DM_NVN_TSV=str(directory / 'performance.tsv'), DM_NVN_TSV_CALLS='0',
                    DM_NVN_SHDUMP=str(WORK / 'run/shdump'), DM_SVC='1', DM_FS='1')
    if args.capture_shaders:
        settings['DM_NVN_CAPTURE'] = '1'
    settings['DM_NVN_SHOT'] = f'1,60,300,900,1500,2400,3300:{directory}/frame-%d.png'
    if args.keys:
        settings['DM_KEYS'] = args.keys
    if args.inspect_frame:
        settings.update(DM_NVN_PASSDUMP=str(args.inspect_frame), DM_NVN_PASSDUMP_ALL='1',
                        DM_NVN_TEXDUMP=f'{args.inspect_frame}:{directory}/tex-%d.png', DM_NVN_TEXCPU='1')
    if args.seconds:
        settings['DM_WATCH'] = str(args.seconds)
    log = directory / 'boot.log'
    termination = 'exited'
    with log.open('w') as output:
        process = subprocess.Popen([str(binary), str(WORK / 'rewrite'), *profile()['runtime_modules']],
                                   env=env() | settings, stdout=output, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=args.seconds + 15 if args.seconds else None)
        except subprocess.TimeoutExpired:
            termination = 'external-timeout'
            process.terminate()
            try:
                code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); code = process.wait()
    text = log.read_text(errors='replace')
    errors = [line for line in text.splitlines() if any(x in line for x in ('FATAL', 'UNIMPL', '【红】', 'CRASH'))]
    reached = [label for marker, label in [('>>> nnosInitialize', 'sdk-initialize'), ('>>> nninitStartup', 'sdk-startup'),
                                            ('>>> nnMain', 'nnMain')] if marker in text]
    save(directory / 'receipt.json', {'run_id': stamp, 'reached': reached, 'exit_code': code,
         'termination': termination, 'first_failure': errors[0] if errors else None, 'host_sha256': sha(binary),
         'rewrite': fingerprints(), 'unverified': ['first-frame', 'input', 'gameplay', 'audio', 'save-roundtrip']})
    print(f'Native log: {log}\nReached: {reached}\nFirst failure: {errors[0] if errors else "inspect log"}')
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('bootstrap', 'rewrite', 'verify', 'shaders', 'build'):
        commands.add_parser(name)
    prep = commands.add_parser('prepare')
    prep.add_argument('--base', type=Path, required=True)
    prep.add_argument('--update', type=Path, required=True)
    prep.add_argument('--keys', type=Path, required=True, help='Your own local keyset; never uploaded or required at runtime')
    start = commands.add_parser('run')
    start.add_argument('--seconds', type=int, default=30)
    start.add_argument('--capture-shaders', action='store_true', help='Diagnostic only: missing stages may omit draws')
    start.add_argument('--keys', help='Timed diagnostic gamepad input using the upstream DM_KEYS syntax')
    start.add_argument('--inspect-frame', type=int, help='Dump actual pass bindings and render targets')
    args = parser.parse_args()
    if args.command == 'run' and not 0 <= args.seconds <= 600:
        parser.error('--seconds must be 0..600; 0 leaves the window open')
    WORK.mkdir(exist_ok=True)
    try:
        return {'bootstrap': bootstrap, 'prepare': prepare, 'rewrite': rewrite, 'verify': verify,
                'shaders': shaders, 'build': build, 'run': launch}[args.command](args) or 0
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    sys.exit(main())
