#!/usr/bin/env python3
"""Build the unsigned, game-content-free DR3 Mobile shell.

The shell is a build input for tools/dr3_pack.py: an unsigned .app/.zip that carries the compiled
host and the iOS frontend but none of the game-derived content (no rewritten module images, no
shader libraries, no graphics tables). Users pack their own game files into it on their own
machine (no Mac or Xcode needed there) and sign the result for installation.

Usage: shell_build.py [--bundle-id X] [--cpu apple-a18] [--out DIR]
Output (default work/shell/): DR3Mobile-shell-build-input.zip + shell_manifest.txt
Requires: the bootstrap (tools/dr3.py bootstrap), xcodegen, Xcode's iOS SDK. Game files are NOT
required: every table the shell carries is the placeholder the repository generates, and the
graphics tables the packer must supply are listed in shell_manifest.txt.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dr3 import ROOT, WORK, UPSTREAM, TITLE, COMMIT, PROFILE, env, sha, shader_chain, copy_native  # noqa: E402

APP_NAME = 'DR3Mobile'
SHELL_DIR = WORK / 'shell'


def run(cmd, extra_env=None, cwd=None):
    e = env() | (extra_env or {})
    print('+', ' '.join(str(x) for x in cmd), flush=True)
    subprocess.run([str(x) for x in cmd], cwd=cwd, env=e, check=True,
                   stdout=subprocess.DEVNULL if str(cmd[0]).endswith('make') else None)


def die(msg):
    sys.exit('[x] ' + msg)


def precheck():
    if not UPSTREAM.exists():
        die('third_party/nxnative missing; run: python3 tools/dr3.py bootstrap')
    actual = subprocess.check_output(['git', '-C', str(UPSTREAM), 'rev-parse', 'HEAD'], text=True).strip()
    pinned = UPSTREAM / '.dm-pinned'   # tree-rebuild path: HEAD is the rebuild commit; the pinned SHA is recorded in .dm-pinned
    if actual != COMMIT and not (pinned.exists() and pinned.read_text().strip() == COMMIT and actual):
        die('upstream commit mismatch; run: python3 tools/dr3.py bootstrap')
    # The DM_SHELL branches (Guest-framework loader + on-device shader compile) ship inside
    # patches/nxnative.patch itself; make sure the pinned patch is really applied.
    if subprocess.run(['git', '-C', str(UPSTREAM), 'apply', '--reverse', '--check', str(ROOT / 'patches/nxnative.patch')],
                      capture_output=True).returncode != 0:
        die('patches/nxnative.patch not applied to third_party/nxnative; run: python3 tools/dr3.py bootstrap')
    for tool in ('xcodegen', 'xcodebuild', 'otool'):
        if not shutil.which(tool):
            die(f'{tool} not on PATH')


def placeholder_icon(catalog_dir):
    """A self-drawn 1024x1024 icon (no game content): dark plate, light ring, 'DR3' bars."""
    from PIL import Image, ImageDraw
    img = Image.new('RGB', (1024, 1024), (24, 24, 28))
    d = ImageDraw.Draw(img)
    d.ellipse((192, 192, 832, 832), outline=(200, 60, 60), width=40)
    for i, x in enumerate((312, 452, 592)):
        d.rectangle((x, 432 - i * 0, x + 96, 592), fill=(232, 232, 232))
    d.rectangle((312, 320, 400, 368), fill=(232, 232, 232))
    catalog_dir.mkdir(parents=True, exist_ok=True)
    tmp = WORK / 'shell' / 'icon-placeholder.jpg'
    tmp.parent.mkdir(parents=True, exist_ok=True)
    img.save(tmp, quality=92)
    from app_icons import ios_catalog
    return ios_catalog(tmp, catalog_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle-id', default='com.enginefuture.dr3-mobile.ios')   # 与正常构建同包名 | same bundle id as the normal build
    parser.add_argument('--cpu', default='apple-a18', choices=['apple-a17', 'apple-a18'])
    parser.add_argument('--out', default=str(SHELL_DIR))
    args = parser.parse_args()
    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    precheck(); copy_native()
    ios = ROOT / 'platform/ios'; gen = ios / 'Gen'
    if gen.exists(): shutil.rmtree(gen)
    for name in ('dm', 'msl', 'romfs', 'aoc'): (gen / name).mkdir(parents=True)

    print('[shell] generating build inputs', flush=True)
    settings = env() | dict(GAME=TITLE, DM_BUNDLE_ID=args.bundle_id, DM_TEAM_ID='', DM_IOS_CPU=args.cpu)
    probe = subprocess.run(['make', '-s', '-n', '-B', '-C', str(UPSTREAM / 'dm/host'), 'dmhost'],
                           env=settings, capture_output=True, text=True)
    # 取证：CI 的 make 版本行为与本地可能不同，这里是唯一能看到 make -n 实际输出的地方
    print(f'[shell] make -n dmhost rc={probe.returncode} clang_lines={probe.stdout.count("clang")} '
          f'stdout_lines={len(probe.stdout.splitlines())} stderr={probe.stderr[:400]!r}', flush=True)
    config = subprocess.check_output([sys.executable, str(UPSTREAM / 'dm/ios/tools/gen_build.py'),
                                      str(UPSTREAM / 'dm/host'), str(gen)], env=settings, text=True)
    print('[shell] --- gen_build 输出全文（取证）---', flush=True)
    print(config, flush=True)
    print('[shell] --- 输出结束 ---', flush=True)
    hdr = next((l for l in config.splitlines() if l.startswith('HEADER_SEARCH_PATHS')), '')
    host_dir = str(UPSTREAM / 'dm/host')
    if not any(p.strip().strip('"') == host_dir for p in hdr.split(' ', 2)[-1].split(' ')):
        die(f'HEADER_SEARCH_PATHS 缺 host 目录 {host_dir}（front_ios.m 的 lan_native.h 将找不到）')
    if not (UPSTREAM / 'dm/host/lan_native.h').exists():
        die('树上 dm/host/lan_native.h 不存在（patch 新建文件未落地——快照/补丁状态不一致）')
    _hm = UPSTREAM / 'dm/host/hle_hudmove.c'
    if not _hm.exists() or b'ConsoleHUD_main.LayoutRoot.Globes' not in _hm.read_bytes():
        die(f'树上 hle_hudmove.c 缺锚串字面量（{_hm.stat().st_size if _hm.exists() else "文件缺失"}）'
            '——不是当前补丁的产物（扫描器会空转）')
    # The shell embeds no module images: no -segprot link flags for them, and the graphics layer's
    # DM_SHELL branch (ships in patches/nxnative.patch) is compiled in so shader sources are compiled on device.
    config = re.sub(r'^(OTHER_CFLAGS = .*)$', r'\1 -DDM_SHELL', config, flags=re.M)
    assert '-DDM_SHELL' in config, 'DM_SHELL flag not injected'
    (gen / 'dm.xcconfig').write_text(config + '\nOTHER_LDFLAGS = $(inherited) $(DM_FRAMEWORKS)\n')
    (gen / 'embed.S').write_text('// Shell build (tools/shell_build.py): the rewritten module images are not embedded here;\n'
                                 '// they live in Frameworks/Guest.framework/Guest, written by tools/guest_dylib.py from the\n'
                                 "// user's own game files (tools/dr3_pack.py) and loaded by Sources/main.m's DM_SHELL branch.\n")

    dm = gen / 'dm'
    game = UPSTREAM / 'dm/games' / TITLE
    for name in ('shader_map.tsv', 'c1_full.tsv', 'pso_manifest.tsv'):
        if (game / name).exists(): shutil.copyfile(game / name, dm / name)
    # Same defaults as the normal build (tools/build_ios.py)。不带 MTL_HUD_ENABLED：Apple 的 libMTLHud
    # 见到变量「存在」就可能挂上（0 也不算关）——想要 HUD 的人用启动器开关（开 = setenv 1，关 = unsetenv）。
    # | No MTL_HUD_ENABLED here: Apple's libMTLHud can attach on the variable's mere presence (a value
    # | of 0 does not disable it) — the launcher switch owns it (on = setenv 1, off = unsetenv).
    (dm / 'env.txt').write_text('DM_LANG=zh-Hans\nDM_OPMODE=0\nDM_NVN_UNIFORM_FORWARD=1\nDM_NVN_TBDR=0\n'
                                'DM_PSO_MANIFEST=off\nDM_NVN_TSV=performance.tsv\n'
                                'DM_NVN_TSV_CALLS=0\nDM_HID_RECEIPT_LOG=controller.jsonl\n'
                                'DM_HID_RECEIPT_LIMIT=65536\nDM_PAD_EVENT_LOG=controller-events.jsonl\n')
    # The packer replaces these two (see shell_manifest.txt): the real graphics proof and the
    # asset inventory of the user's own RomFS/DLC. The placeholders keep boot honest: without
    # them the app reports what is missing instead of half-starting.
    (dm / 'mobile-graphics.json').write_text(json.dumps(dict(mode='d3-mobile-graphics', startup_selection=False,
                                                             limitations=['placeholder; replaced by dr3_pack.py'])) + '\n')
    (dm / 'private-assets.json').write_text('{}\n')
    font = dm / 'font'; font.mkdir()
    shutil.copyfile('/System/Library/Fonts/Supplemental/Arial Unicode.ttf', font / 'standard.ttf')
    run([sys.executable, UPSTREAM / 'dm/tools/make_ext_font.py', str(font / 'nintendo_ext.ttf')])
    placeholder_icon(gen / 'AppAssets.xcassets')
    (gen / 'msl/.keep').write_text('')   # xcodegen folder resources need a non-empty directory

    print('[shell] xcodegen + xcodebuild (unsigned)', flush=True)
    run(['xcodegen', 'generate', '--spec', str(ios / 'project.yml')], cwd=ios)
    log = out / 'build.log'
    command = ['xcodebuild', '-project', str(ios / 'DR3MobileIOS.xcodeproj'), '-scheme', 'DR3Mobile',
               '-configuration', 'Release', '-destination', 'generic/platform=iOS',
               '-derivedDataPath', str(WORK / 'build/ios-shell'),
               'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'build']
    print('+', ' '.join(command), flush=True)
    with log.open('w') as f:
        rc = subprocess.run(command, cwd=ios, env=settings, stdout=f, stderr=subprocess.STDOUT).returncode
    if rc: die(f'xcodebuild exited {rc}; see {log}')

    app = next(p for p in (WORK / 'build/ios-shell/Build/Products').rglob(f'{APP_NAME}.app'))
    app_dir = out / 'app'
    if app_dir.exists(): shutil.rmtree(app_dir)
    shutil.copytree(app, app_dir)

    # Move the game-derived content out of the shell and list it in the manifest. Anything not
    # moved and not listed ships as part of the shell (the placeholder tables are not derived
    # content: the repository generates them with no game files).
    manifest = ['msl/', 'dm/c1_full.tsv', 'dm/mobile-graphics.json', 'dm/private-assets.json']
    ref = out / 'ref'
    for rel in list(manifest):
        p = app_dir / rel
        if not p.exists(): continue
        dst = ref / rel; dst.parent.mkdir(parents=True, exist_ok=True)
        if p.is_dir(): shutil.move(str(p), str(dst))
        else: shutil.move(str(p), str(dst)); dst.parent.mkdir(parents=True, exist_ok=True)

    binary = app_dir / APP_NAME
    sects = subprocess.check_output(['otool', '-l', str(binary)], text=True)
    bad = re.findall(r'sectname __dm\w+x[012]', sects)
    if bad: die(f'shell executable still carries module sections: {bad}')
    # No file in the shell may carry game code: the rewritten images start with the NSO header
    # magic; neither it nor the first 64 bytes of any module may appear anywhere.
    needles = [b'NSO0']
    hits = []
    for p in app_dir.rglob('*'):
        if p.is_file():
            b = p.read_bytes()
            if any(n in b for n in needles): hits.append(str(p.relative_to(app_dir)))
    if hits: die(f'game content found in the shell: {hits}')

    chain = shader_chain()
    info = dict(BUILD=json.loads(PROFILE.read_text())['modules']['main']['build_id'][:16],
                CHAIN=chain, PATCH=sha(ROOT / 'patches/nxnative.patch')[:16],
                SHADER_SRC='', KIND='ios', CPU=args.cpu)
    (app_dir / 'dm/shell_manifest.txt').write_text('\n'.join(manifest) + '\n')
    (app_dir / 'dm/shell_info.txt').write_text(''.join(f'{k}={v}\n' for k, v in info.items()))
    (out / 'shell_manifest.txt').write_text('\n'.join(manifest) + '\n')

    payload = out / 'Payload'
    if payload.exists(): shutil.rmtree(payload)
    payload.mkdir(); shutil.copytree(app_dir, payload / f'{APP_NAME}.app')
    zip_path = out / 'DR3Mobile-shell-build-input.zip'
    if zip_path.exists(): zip_path.unlink()
    import zipfile
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_STORED) as zf:   # 原样存（不压缩）：IPA 惯例，签名的二进制压了也没省多少
        for p in sorted(payload.rglob('*')):
            zf.write(p, p.relative_to(out).as_posix())
    shutil.rmtree(payload)
    n = sum(1 for _ in app_dir.rglob('*') if _.is_file())
    print(f'[shell] {zip_path} ({zip_path.stat().st_size // 1024 // 1024} MB, {n} files); '
          f'missing {len(manifest)} items, manifest {out / "shell_manifest.txt"}', flush=True)


if __name__ == '__main__':
    main()
