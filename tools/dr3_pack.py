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
#   壳（DM_SHELL 构建，patches/shell.patch）在设备上第一次用到每个着色器时现编，系统缓存后不再耗时。
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
    e = dict(os.environ, DM_ROOT=str(WORK), PYTHONUTF8='1'); e.update(env or {})
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
    text = (UPSTREAM / 'dm/games' / TITLE / 'dmsh_chain.h').read_text()
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
    args = parser.parse_args()
    game = Path(args.game_dir); out = Path(args.out_ipa)
    check_env()

    z, base, manifest, info = read_shell(args.shell_zip)
    profile = json.loads(PROFILE.read_text())
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

    chain = local_chain()
    if info.get('CHAIN') and info['CHAIN'] != chain:
        die('着色器链版本与壳不一致（壳要 %s，本地是 %s）：换与壳同源的仓库版本' % (info['CHAIN'], chain))

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

    # 着色器：抽包 → 打包 → 翻译（无编译器模式，出源码）→ c1 表
    def shaders_done():
        d = WORK / 'build/cache/metal_shader_cache' / ('b-' + chain)
        return (d / '_b_build.json').exists() and (WORK / 'shaders/pack-c1_full.tsv').exists()
    step('着色器：抽包与翻译（源码模式，设备上现编）', shaders_done, lambda: (
        run([sys.executable, ROOT / 'tools/cpk_shaders.py'], log=WORK / 'logs/pack-cpk-shaders.log'),
        run([sys.executable, ROOT / 'tools/shader_packages.py'], log=WORK / 'logs/pack-shader-packages.log'),
        run([sys.executable, UPSTREAM / 'dm/gfx/tools/dmsh_chain.py', '--update-lock'], log=WORK / 'logs/pack-shader-lock.log'),
        run([sys.executable, UPSTREAM / 'dm/gfx/tools/dmsh_chain.py', '--header'], log=WORK / 'logs/pack-chain.log'),
        die('着色器链版本变了（%s → %s）：与壳不同源' % (info.get('CHAIN'), local_chain())) if info.get('CHAIN') and local_chain() != info['CHAIN'] else None,
        run([sys.executable, ROOT / 'tools/nometal_run.py', UPSTREAM / 'dm/gfx/tools/dmsh_build.py',
             WORK / 'shaders/package', WORK / 'build/cache/metal_shader_cache'], log=WORK / 'logs/pack-build-shaders.log'),
        run([sys.executable, UPSTREAM / 'dm/gfx/tools/c1_guard.py', WORK / 'build/cache/metal_shader_cache' / ('b-' + chain),
             WORK / 'shaders/pack-c1_full.tsv'], log=WORK / 'logs/pack-c1-guard.log')))
    result = json.loads((WORK / 'build/cache/metal_shader_cache' / ('b-' + chain) / '_b_build.json').read_text())
    if any(row['st'] != 'ok' for row in result): die('着色器翻译有失败项：见 work/logs/pack-build-shaders.log')

    # 宽屏画像证明（normal 画像；壳版不开宽屏：Guest v1 只带一份 main 映像）
    proof_dir = WORK / 'ios-profiles/pack'
    def graphics_done(): return (proof_dir / 'graphics.json').exists()
    step('宽屏画像校验', graphics_done, lambda: (
        sys.path.insert(0, str(HERE)),
        __import__('mobile_graphics_profile').launch_directory(WORK, proof_dir, 1568, 720)))
    graphics = json.loads((proof_dir / 'graphics.json').read_text())
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
    import guest_dylib
    fw, n = guest_dylib.write(str(WORK / 'rewrite'), str(app / 'Frameworks'), mods)
    say('Guest.framework：%d 字节（%s）' % (n, ', '.join(mods)))
    # 缺的内容：着色器源码库、真实图形表、真实资源清单
    msl_src = WORK / 'build/cache/metal_shader_cache' / ('b-' + chain)
    msl_dst = app / 'msl' / ('b-' + chain); msl_dst.parent.mkdir(parents=True, exist_ok=True)
    if msl_dst.exists(): shutil.rmtree(msl_dst)
    shutil.copytree(msl_src, msl_dst)
    shutil.copyfile(WORK / 'shaders/pack-c1_full.tsv', app / 'dm/c1_full.tsv')
    (app / 'dm/mobile-graphics.json').write_text(json.dumps(graphics, indent=1) + '\n')
    assets = {}
    for kind, directory in [('romfs', romfs), ('aoc', game / 'aoc')]:
        assets[kind] = {p.relative_to(directory).as_posix(): p.stat().st_size
                        for p in directory.rglob('*') if p.is_file()} if directory.exists() else {}
    (app / 'dm/private-assets.json').write_text(json.dumps(assets) + '\n')
    # 核对：清单里的项都做进去了
    missing = [m for m in manifest if not (app / m.rstrip('/')).exists()]
    if missing: die('清单里的内容还没做齐：%s' % missing)
    (app / 'dm/shell_info.txt').write_text('')   # 已填完，不再当壳
    (app / 'dm/shell_manifest.txt').unlink(missing_ok=True)

    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_STORED) as oz:
        for p in app.parent.rglob('*'):
            oz.write(p, p.relative_to(app.parent).as_posix())
    say('好了：%s（%d MB）。用 Sideloadly / AltStore 签名装机；首次启动停在「正在准备着色器」属正常。' % (out, out.stat().st_size // 1024 // 1024))


if __name__ == '__main__':
    main()
