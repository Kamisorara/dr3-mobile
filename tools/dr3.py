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


def bootstrap(_):
    if not UPSTREAM.exists():
        run(['git', 'clone', 'https://github.com/seedds/nxnative.git', UPSTREAM], WORK / 'logs/clone.log')
        run(['git', 'checkout', COMMIT], WORK / 'logs/checkout.log', cwd=UPSTREAM)
    actual = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != COMMIT:
        raise ValueError('Upstream commit mismatch; use the pinned clean checkout')
    patch = ROOT / 'patches/nxnative.patch'
    applied = subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=UPSTREAM, capture_output=True).returncode == 0
    if not applied:
        run(['git', 'apply', '--check', patch], WORK / 'logs/patch-check.log', cwd=UPSTREAM)
        run(['git', 'apply', patch], WORK / 'logs/patch.log', cwd=UPSTREAM)
    shell_patch = ROOT / 'patches/shell.patch'
    shell_done = subprocess.run(['git', 'apply', '--reverse', '--check', str(shell_patch)], cwd=UPSTREAM, capture_output=True).returncode == 0
    if not shell_done:
        run(['git', 'apply', '--check', shell_patch], WORK / 'logs/shell-patch-check.log', cwd=UPSTREAM)
        run(['git', 'apply', shell_patch], WORK / 'logs/shell-patch.log', cwd=UPSTREAM)
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
            (game / name).write_text('# D3 inventory pending; no graphics validation\n')
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
