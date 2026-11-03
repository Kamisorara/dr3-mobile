#!/usr/bin/env python3
# 不用 Xcode 出可玩的安装包：把你自己的游戏文件做进「壳」。
#   壳（DR3Mobile-shell-build-input.zip，构建原料、不能直接安装）是一个不含任何游戏内容、没有签名的安装包（CI 由 tools/shell_build.py 出）；
#   本工具用你的游戏文件在你的电脑上生成它缺的全部内容（改写后的游戏程序、着色器源码、宽屏画像证明、资源清单），放进去，写出一个新的安装包。
#   之后用自签工具整包签名装机。游戏文件只在本机读，不上传；做出来的安装包里有游戏内容，请只自己用，不要分发。
# 用法：dr3_pack.py <壳.zip> <游戏文件目录> <输出.ipa> [--skip-verify]
#   游戏文件目录 = Switch 版 2.7.7.92380 的 Update 目录，里面有 ExeFS/{main,sdk} 与 RomFS/…（怎么从自己的游戏导出见 docs/BUILD.md）
#   工作目录（缓存与中间产物）：环境变量 DM_ROOT，缺省 ~/dm-work；每步做过就跳过
#   --skip-verify 跳过改写等价试验（Unicorn，最耗时的一步）；正常构建不建议
# 需要：Python 3.12+ 与 requirements.txt 里的包（pillow numpy lz4 capstone unicorn fonttools）；.NET SDK（着色器翻译工具）；
#   spirv-cross；先跑过 tools/dr3.py bootstrap。缺什么开头逐项报。
# 着色器：本工具按「没有苹果编译器」的模式跑出库链（gfx/tools/nometal_run.py），「库文件」里放的是 MSL 源码；
#   壳（DM_SHELL 构建，该分支随 patches/nxnative.patch 自带）在设备上第一次用到每个着色器时现编，系统缓存后不再耗时。
# 先跑本工具前壳与仓库要同源：壳里 shell_info.txt 的 CHAIN/PATCH 与本地 dmsh_chain 链版本、补丁指纹对不上会当场拒绝。
import argparse, json, os, re, shutil, subprocess, sys, time, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
UPSTREAM = ROOT / 'third_party/nxnative'
WORK = ROOT / 'work'
TITLE = '01001B300B9BE000'
PROFILE = ROOT / 'config/diablo3-2.7.7.json'


def say(s): print('[%s] %s' % (time.strftime('%H:%M:%S'), s), flush=True)


def die(s): sys.exit('[x] ' + s)


def sha(path):
    import hashlib
    with open(path, 'rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def run(cmd, env=None, log=None):
    e = dict(os.environ, DM_ROOT=str(WORK), DM_GAME=TITLE, DM_RULESET='native', DM_PRIVATE_GATES='0',
             PYTHONUTF8='1')   # 与 tools/dr3.py env() 同一套基础环境 | the same base environment as tools/dr3.py env()
    e.update(env or {})
    say(' '.join(str(x) for x in cmd[:3]) + ' …')
    log = log or (WORK / 'logs' / ('pack-' + Path(str(cmd[2] if len(cmd) > 2 else cmd[0])).stem + '.log'))
    log.parent.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(x) for x in cmd], env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_bytes(r.stdout)
    if r.returncode: die('%s 没成功（退出码 %d）：见 %s\n%s' % (cmd[0], r.returncode, log,
                          r.stdout.decode('utf-8', 'replace').strip().splitlines()[-1:]))
    return r.stdout.decode('utf-8', 'replace')


def read_shell(zip_path):
    try: z = zipfile.ZipFile(zip_path)
    except zipfile.BadZipFile: die('这个文件不是安装包（解不开）：%s' % zip_path)
    apps = sorted({n.split('/')[1] for n in z.namelist() if n.startswith('Payload/') and n.count('/') >= 2 and n.split('/')[1].endswith('.app')})
    if len(apps) != 1: die('壳里的 App 不是恰好一个：%s' % apps)
    base = 'Payload/%s/' % apps[0]
    try:
        manifest = [l.strip() for l in z.read(base + 'dm/shell_manifest.txt').decode().splitlines() if l.strip()]
        info = dict(l.strip().split('=', 1) for l in z.read(base + 'dm/shell_info.txt').decode().splitlines() if '=' in l)
    except KeyError: die('这不是壳：里面没有 dm/shell_manifest.txt / dm/shell_info.txt')
    return z, base, manifest, info


def check_env():
    bad = []
    for m in ('PIL', 'numpy', 'lz4', 'capstone', 'unicorn', 'fontTools'):
        try: __import__(m)
        except Exception: bad.append('Python 包 %s：python3 -m pip install -r requirements.txt' % m)
    dotnet = shutil.which('dotnet')
    if not dotnet: bad.append('.NET SDK（着色器翻译工具用）：https://dotnet.microsoft.com/download')
    if not shutil.which('spirv-cross'): bad.append('spirv-cross（着色器翻译用）')
    if not (UPSTREAM / 'dm/games' / TITLE / 'game.tsv').exists(): bad.append('bootstrap 没跑过：python3 tools/dr3.py bootstrap')
    if bad:
        print('[x] 缺少：'); [print('  · ' + b) for b in bad]; sys.exit(1)


def local_chain():
    text = (UPSTREAM / 'dm/games' / TITLE / 'dmsh_chain.h').read_text(encoding='utf-8')
    return re.search(r'#define DMSH_CHAIN "([0-9a-f]{12})"', text).group(1)


def step(name, done, fn):
    if done(): say('%s：已有，跳过' % name); return
    t0 = time.time(); say(name); fn()
    if not done(): die('%s 做完了但没看到产物' % name)
    say('%s 完成（%d 秒）' % (name, time.time() - t0))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('shell_zip'); parser.add_argument('game_dir'); parser.add_argument('out_ipa')
    parser.add_argument('--skip-verify', action='store_true')
    parser.add_argument('--bundle-id', default='com.enginefuture.dr3-mobile.ios',
                        help='安装包名（缺省 = 正常构建的原包名；自签工具通常还会再改成你自己的）')
    parser.add_argument('--icon', default='', help='App 图标（正方形 jpg/png；缺省保留壳的占位图标）。游戏的原图标在 NCA 控制分区，'
                        '这里自备一张即可：做成 120px 与 152px 的松散 PNG 并改 Info.plist 指向它们（Windows 上没有 actool 重编 Assets.car）')
    args = parser.parse_args()
    game = Path(args.game_dir); out = Path(args.out_ipa)
    check_env()

    z, base, manifest, info = read_shell(args.shell_zip)
    profile = json.loads(PROFILE.read_text(encoding='utf-8'))
    mods = profile['runtime_modules']
    if info.get('BUILD') != profile['modules']['main']['build_id'][:16]:
        die('壳是给别的游戏版本出的（BUILD=%s，本地要 %s）：重新出壳或换壳' % (info.get('BUILD'), profile['modules']['main']['build_id'][:16]))
    if info.get('PATCH') != sha(ROOT / 'patches/nxnative.patch')[:16]:
        die('壳出的时代与本地 patches/nxnative.patch 不同（%s vs %s）：换与壳同源的仓库版本' % (info.get('PATCH'), sha(ROOT / 'patches/nxnative.patch')[:16]))

    exefs = game / 'ExeFS'
    for name in mods:
        src = exefs / name
        if not src.exists(): die('游戏文件缺 %s' % src)
        if sha(src) != profile['modules'][name]['sha256']: die('%s：SHA-256 与登记的不一致（版本不对？）' % name)
    (WORK / 'game/ExeFS').mkdir(parents=True, exist_ok=True)
    for name in mods: shutil.copyfile(exefs / name, WORK / 'game/ExeFS' / name)
    romfs = game / 'RomFS'
    if not (romfs / profile.get('romfs_marker', 'CPKs/CoreCommon.cpk')).exists():
        die('RomFS 缺 %s（目录对不对？）' % profile.get('romfs_marker'))
    # 着色器抽取从 work/game/RomFS 读（tools/cpk_shaders.py）；资源本体不进安装包，这里只放目录联接
    # | shader extraction reads work/game/RomFS (tools/cpk_shaders.py); the assets themselves never enter the package, this link is for the build only
    for name, src in (('RomFS', romfs), ('aoc', game / 'aoc')):
        dst = WORK / 'game' / name
        if dst.is_symlink() or dst.is_file(): dst.unlink()
        if not dst.exists():
            try: dst.symlink_to(src.resolve(), target_is_directory=True)
            except OSError: die('建目录联接失败 %s（Windows 需开发者模式）：mklink /J %s %s' % (dst, dst, src.resolve()))
        elif not dst.is_symlink(): die('%s 已存在且不是联接，请移开后重跑' % dst)

    shell_chain = info.get('CHAIN') or ''   # 壳编译期的占位口径；真实口径见装配阶段的二进制重写 | the shell's placeholder digest; the real one is handled at assembly time

    def rewritten():
        return all((WORK / 'rewrite' / f'{n}.patched.bin').exists() for n in mods)

    def do_rewrite():
        for n in mods:
            run([sys.executable, UPSTREAM / 'dm/tools/patch_nso.py', WORK / 'game/ExeFS' / n, WORK / 'rewrite', n],
                log=WORK / 'logs' / f'pack-rewrite-{n}.log')

    step('改写游戏程序', rewritten, do_rewrite)

    def do_verify():
        for n in mods:
            for script in ('structck.py', 'equiv.py'):
                run([sys.executable, UPSTREAM / 'dm/verify' / script, WORK / 'rewrite', n,
                     WORK / 'game/ExeFS' / n] + (['--jobs', '4', '--seed', '1', '--mutate', '100'] if 'equiv' in script else []),
                    log=WORK / 'logs' / f'pack-verify-{n}-{Path(script).stem}.log')
        (WORK / 'verification.json').write_text(json.dumps(dict(passed=True, skipped=False, mode='pack')))

    if not args.skip_verify:
        step('改写等价验证', lambda: (WORK / 'verification.json').exists(), do_verify)
    else:
        (WORK / 'verification.json').write_text(json.dumps(dict(passed=True, skipped=True, mode='pack')))

    # 着色器：抽包 → 打包 → 翻译（无编译器模式，出源码）→ c1 表。
    # 不跑 dmsh_chain --update-lock / --header：锁内容参与链版本，一重算链就漂、与壳失配（壳认它编进二进制的 V）。
    # | No dmsh_chain --update-lock / --header: the lock content feeds the chain version; recalculating it would drift
    # | away from the shell (the shell binary only loads its compiled-in V).
    dotnet = shutil.which('dotnet')
    xl = WORK / 'build/gfx/dmsh_xlate'
    xlate = xl / ('dmsh_xlate.exe' if os.name == 'nt' else 'dmsh_xlate')
    def xlate_done(): return xlate.exists()
    step('编译着色器翻译工具（.NET）', xlate_done,
         lambda: run([dotnet, 'publish', UPSTREAM / 'dm/gfx/tools/dmsh_xlate', '-c', 'Release', '-o', str(xl), '-v', 'quiet'],
                     log=WORK / 'logs/pack-xlate.log'))
    def shaders_done():
        d = WORK / 'build/cache/metal_shader_cache' / ('b-' + local_chain())
        return (d / '_b_build.json').exists() and (WORK / 'shaders/pack-c1_full.tsv').exists()
    # 注意：shader_packages 会把真实表写进游戏档案，链版本从壳的占位口径（壳在 CI 上没有游戏文件）切到本机真实口径。
    # 宿主二进制只认编译期那个 V；装配阶段把二进制里的链版本常量原地改写成本机口径（12 字节等长 hex，壳无签名，装机时整包重签）。
    # | shader_packages writes the real tables into the game profile, so the chain version moves from the shell's
    # | placeholder digest (CI has no game files) to this machine's real one. The host binary only trusts the V it was
    # | compiled with; the assembly stage rewrites that 12-byte constant in place (equal length, unsigned shell, the
    # | whole package gets re-signed at install time anyway).
    step('着色器：抽包与翻译（源码模式，设备上现编）', shaders_done, lambda: (
        run([sys.executable, ROOT / 'tools/cpk_shaders.py'], log=WORK / 'logs/pack-cpk-shaders.log'),
        run([sys.executable, ROOT / 'tools/shader_packages.py'], log=WORK / 'logs/pack-shader-packages.log'),
        run([sys.executable, UPSTREAM / 'dm/gfx/tools/dmsh_chain.py', '--header'], log=WORK / 'logs/pack-chain-header.log'),   # dmsh_chain.h 是生成物、不参与 V 计算；真实表入库后要与 dmsh_build 的口径一致 | dmsh_chain.h is generated and does not feed V; it must match dmsh_build once the real tables land
        run([sys.executable, ROOT / 'tools/nometal_run.py', UPSTREAM / 'dm/gfx/tools/dmsh_build.py',
             WORK / 'shaders/package', WORK / 'build/cache/metal_shader_cache'],
            env={'XLATE': str(xlate)}, log=WORK / 'logs/pack-build-shaders.log'),
        run([sys.executable, UPSTREAM / 'dm/gfx/tools/c1_guard.py', WORK / 'build/cache/metal_shader_cache' / ('b-' + local_chain()),
             WORK / 'shaders/pack-c1_full.tsv'], log=WORK / 'logs/pack-c1-guard.log')))
    chain = local_chain()   # 真实口径（真实表入档后） | the real digest (real tables now in the profile)
    say('本机链版本：%s（壳编译期：%s）' % (chain, info.get('CHAIN')))
    result = json.loads((WORK / 'build/cache/metal_shader_cache' / ('b-' + chain) / '_b_build.json').read_text(encoding='utf-8'))
    if any(row['st'] != 'ok' for row in result): die('着色器翻译有失败项：见 work/logs/pack-build-shaders.log')

    # 画像文件（壳版不开宽屏：Guest v1 只带一份 main 映像，startup_selection 恒为 false）。
    # 完整模式：跑真实的画像校验（要求改写验证已过）；--skip-verify：写占位，App 按普通 16:9 启动。
    # | Graphics file (the shell never enables widescreen: Guest v1 carries a single main image, startup_selection is
    # | always false). Full mode runs the real graphics proof (requires rewrite verification); --skip-verify writes a
    # | placeholder and the app starts at plain 16:9.
    graphics = dict(mode='d3-mobile-graphics', startup_selection=False,
                    limitations=['Shell pack without rewrite verification: no graphics proof; normal 16:9 only.'])
    if not args.skip_verify:
        proof_dir = WORK / 'ios-profiles/pack'
        def graphics_done(): return (proof_dir / 'graphics.json').exists()
        step('宽屏画像校验', graphics_done, lambda: (
            sys.path.insert(0, str(HERE)),
            __import__('mobile_graphics_profile').launch_directory(WORK, proof_dir, 1568, 720)))
        graphics = json.loads((proof_dir / 'graphics.json').read_text(encoding='utf-8'))
        import mobile_graphics_profile as mobile
        original = (WORK / 'rewrite/main.patched.bin').read_bytes()
        proof = mobile.verify(original)
        if not proof['passed'] or proof['configured_sha256'] != graphics.get('configured_sha256'):
            die('宽屏画像校验失败：改写产物与画像不匹配')
        graphics.update(startup_selection=False, verification=proof, normal_image_sha256=sha(WORK / 'rewrite/main.patched.bin'),
                        limitations=graphics.get('limitations', []) + ['Shell pack: widescreen profile not embedded (single Guest image).'])

    # 装配
    say('装配安装包')
    unpack = WORK / 'pack/unpack'; shutil.rmtree(unpack, ignore_errors=True); unpack.mkdir(parents=True)
    z.extractall(unpack)
    app = unpack / base.rstrip('/')
    # Guest 动态库（装载器的 DM_SHELL 分支从 Frameworks/Guest.framework/Guest 取模块映像节）
    sys.path.insert(0, str(HERE))   # python -I 不加脚本目录：同目录工具模块手动入路径 | python -I omits the script dir: add it for the sibling tool modules
    import guest_dylib
    fw, n = guest_dylib.write(str(WORK / 'rewrite'), str(app / 'Frameworks'), mods)
    say('Guest.framework：%d 字节（%s）' % (n, ', '.join(mods)))
    # 缺的内容：着色器源码库、真实图形表、真实资源清单
    msl_src = WORK / 'build/cache/metal_shader_cache' / ('b-' + chain)
    msl_dst = app / 'msl' / ('b-' + chain); msl_dst.parent.mkdir(parents=True, exist_ok=True)
    if msl_dst.exists(): shutil.rmtree(msl_dst)
    shutil.copytree(msl_src, msl_dst)
    # 宿主二进制的链版本常量改写为本机真实口径（占位口径 ≠ 真实口径是壳模式固有的：CI 出壳时没有游戏文件）。
    # | Rewrite the host binary's chain-version constant to this machine's real digest (placeholder ≠ real is inherent
    # | to the shell: CI builds it without game files). Equal length hex, expected exactly one occurrence.
    binary = app / 'DR3Mobile'
    bindata = binary.read_bytes()
    if shell_chain and shell_chain != chain:
        n_hits = bindata.count(shell_chain.encode())
        if n_hits != 1: die('宿主二进制里链版本常量出现 %d 处（预期 1 处），不敢盲改' % n_hits)
        bindata = bindata.replace(shell_chain.encode(), chain.encode())
        binary.write_bytes(bindata)
        say('宿主链版本常量已改写：%s → %s' % (shell_chain, chain))
    shutil.copyfile(WORK / 'shaders/pack-c1_full.tsv', app / 'dm/c1_full.tsv')
    (app / 'dm/mobile-graphics.json').write_text(json.dumps(graphics, indent=1) + '\n')
    assets = {}
    for kind, directory in [('romfs', romfs), ('aoc', game / 'aoc')]:
        assets[kind] = {p.relative_to(directory).as_posix(): p.stat().st_size
                        for p in directory.rglob('*') if p.is_file()} if directory.exists() else {}
    (app / 'dm/private-assets.json').write_text(json.dumps(assets) + '\n')
    # Info.plist：包名改回正常构建的原包名（旧壳 zip 里是构建期占位）；--icon 自备方图时一并换图标——
    # 覆盖壳的占位图标并改走松散 PNG 路由（Windows 上没有 actool 重编 Assets.car）。
    # | Info.plist: restore the normal build's bundle id (older shell zips carry the build-time placeholder);
    # | with --icon (a square image) also replace the placeholder icon and switch to loose PNGs — there is no actool
    # | on Windows to recompile Assets.car.
    import plistlib
    plist = plistlib.loads((app / 'Info.plist').read_bytes())
    plist['CFBundleIdentifier'] = args.bundle_id
    if args.icon:
        from PIL import Image
        img = Image.open(args.icon).convert('RGB')
        w, h = img.size; s = min(w, h)
        img = img.crop(((w - s) // 2, (h - s) // 2, (w - s) // 2 + s, (h - s) // 2 + s))   # 中心正方形 | center square
        for name, px in (('AppIcon60x60@2x.png', 120), ('AppIcon76x76@2x~ipad.png', 152)):
            img.resize((px, px), Image.LANCZOS).save(app / name)
        plist.pop('CFBundleIconName', None)
        icons = dict(CFBundlePrimaryIcon=dict(CFBundleIconFiles=['AppIcon60x60@2x', 'AppIcon76x76@2x~ipad']))
        plist['CFBundleIcons'] = icons; plist['CFBundleIcons~ipad'] = dict(icons)
        (app / 'Assets.car').unlink(missing_ok=True)   # 只装图标目录；ControlArt 是散装资源不受影响 | the car holds only the icon set; ControlArt ships loose and is unaffected
        say('图标已替换（%s）' % args.icon)
    else:
        say('未给 --icon：保留壳的占位图标（想要游戏图标，找一张方图加 --icon 路径 即可）')
    (app / 'Info.plist').write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))
    say('包名：%s' % args.bundle_id)
    # 核对：清单里的项都做进去了
    missing = [m for m in manifest if not (app / m.rstrip('/')).exists()]
    if missing: die('清单里的内容还没做齐：%s' % missing)
    (app / 'dm/shell_info.txt').write_text('')   # 已填完，不再当壳
    (app / 'dm/shell_manifest.txt').unlink(missing_ok=True)

    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_STORED) as oz:
        for p in sorted(unpack.rglob('*')):
            if p.is_file(): oz.write(p, p.relative_to(unpack).as_posix())   # 带 Payload/ 前缀（IPA 布局） | keep the Payload/ prefix (IPA layout)
    say('好了：%s（%d MB）。用 Sideloadly / AltStore 签名装机；首次启动停在「正在准备着色器」属正常。' % (out, out.stat().st_size // 1024 // 1024))


if __name__ == '__main__':
    main()
