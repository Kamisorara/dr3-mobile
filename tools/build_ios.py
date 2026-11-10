#!/usr/bin/env python3
"""Generate/build the private D3 iOS host from verified modules and iOS shaders."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
from dr3 import ROOT, WORK, UPSTREAM, TITLE, PROFILE, env, sha, save, check_modules, fingerprints, native_fingerprints, copy_native, shader_chain
from app_icons import ios_catalog


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--generate-only',action='store_true')
    parser.add_argument('--bundle-id',default='com.enginefuture.dr3-mobile.ios')
    parser.add_argument('--team-id',default='')
    parser.add_argument('--sign',action='store_true')
    parser.add_argument('--device',default='')
    parser.add_argument('--cpu',default='apple-a18',choices=['apple-a17','apple-a18'],help='Native CPU target; use apple-a17 for iPhone 15 Pro')
    parser.add_argument('--embed-assets',action='store_true',help='Include the private local RomFS and Chinese DLC in this app')
    parser.add_argument('--skin',default='',help='Optional touch-skin PNG directory (Android ui/skin key set) copied to Gen/skin')
    args=parser.parse_args()
    if args.sign and not args.team_id:parser.error('--sign requires an explicit --team-id')
    check_modules();copy_native();verified=json.loads((WORK/'verification.json').read_text())
    if not verified.get('passed') or verified['artifacts']!=fingerprints() or verified['profile_sha256']!=sha(PROFILE):
        raise ValueError('Rewrite verification missing or stale')
    shaders=json.loads((WORK/'shaders/ios-build.json').read_text())
    if shaders['platform']!='iphoneos' or shaders['chain']!=shader_chain():raise ValueError('Wrong iOS shader platform/chain')
    libs=WORK/'shaders/ios'/('b-'+shaders['chain'])
    for name,digest in shaders['files'].items():
        if sha(libs/name)!=digest:raise ValueError('Changed iOS artifact: '+name)
    ios=ROOT/'platform/ios';gen=ios/'Gen'
    if gen.exists():shutil.rmtree(gen)
    for name in ('dm','msl'):(gen/name).mkdir(parents=True)
    icon_source=WORK/'game/icon.jpg'
    icon_png=ios_catalog(icon_source,gen/'AppAssets.xcassets')
    icon_receipt=dict(source_sha256=sha(icon_source),catalog_png_sha256=sha(icon_png),
                      generator_sha256=sha(ROOT/'tools/app_icons.py'))
    settings=env()|dict(GAME=TITLE,DM_BUNDLE_ID=args.bundle_id,DM_TEAM_ID=args.team_id,DM_IOS_CPU=args.cpu)
    config=subprocess.check_output([sys.executable,str(UPSTREAM/'dm/ios/tools/gen_build.py'),str(UPSTREAM/'dm/host'),str(gen)],env=settings,text=True)
    flags=subprocess.check_output([sys.executable,str(UPSTREAM/'dm/ios/tools/gen_embed.py'),str(WORK/'rewrite'),str(gen/'embed.S'),*json.loads(PROFILE.read_text())['runtime_modules']],text=True).strip()
    import mobile_graphics_profile as mobile
    original=(WORK/'rewrite/main.patched.bin').read_bytes()
    proof=mobile.verify(original)
    wide=mobile.launch_directory(WORK,WORK/'ios-profiles'/str(time.time_ns()),1568,720)
    graphics=json.loads((wide/'graphics.json').read_text())
    if not proof['passed'] or proof['configured_sha256']!=graphics['configured_sha256']:
        raise ValueError('Wide image differs from independent graphics verification')
    graphics.update(startup_selection=True,verification=proof,normal_image_sha256=sha(WORK/'rewrite/main.patched.bin'))
    save(gen/'dm/mobile-graphics.json',graphics)
    for suffix in ('patched.bin','fixups.tsv'):
        (wide/('mainwide.'+suffix)).symlink_to((wide/('main.'+suffix)).resolve())
    flags+=' '+subprocess.check_output([sys.executable,str(UPSTREAM/'dm/ios/tools/gen_embed.py'),str(wide),str(wide/'embed-wide.S'),'mainwide'],text=True).strip()
    with (gen/'embed.S').open('a') as output:output.write('\n'+(wide/'embed-wide.S').read_text())
    (gen/'dm.xcconfig').write_text(config+'\nOTHER_LDFLAGS = $(inherited) $(DM_FRAMEWORKS) '+flags+'\n')
    for path in (WORK/'rewrite').glob('*.tsv'):shutil.copy2(path,gen/'dm'/path.name)
    game=UPSTREAM/'dm/games'/TITLE
    for name in ('shader_map.tsv','c1_full.tsv','pso_manifest.tsv'):
        src=game/name
        if src.exists():shutil.copy2(src,gen/'dm'/name)
    shutil.copy2(WORK/'shaders/ios-c1_full.tsv',gen/'dm/c1_full.tsv')
    target=gen/'msl'/libs.name;target.mkdir()
    for name in shaders['files']:shutil.copy2(libs/name,target/name)
    font=gen/'dm/font';font.mkdir()
    shutil.copyfile('/System/Library/Fonts/Supplemental/Arial Unicode.ttf',font/'standard.ttf')
    subprocess.run([sys.executable,str(UPSTREAM/'dm/tools/make_ext_font.py'),str(font/'nintendo_ext.ttf')],check=True,stdout=subprocess.DEVNULL)
    (gen/'dm/env.txt').write_text('DM_LANG=zh-Hans\nDM_OPMODE=0\nDM_NVN_UNIFORM_FORWARD=1\nDM_NVN_TBDR=0\nDM_PSO_MANIFEST=off\nDM_NVN_TSV=performance.tsv\nDM_NVN_TSV_CALLS=0\nDM_HID_RECEIPT_LOG=controller.jsonl\nDM_HID_RECEIPT_LIMIT=65536\nDM_PAD_EVENT_LOG=controller-events.jsonl\n')
    assets={}
    for kind,directory in [('romfs',WORK/'game/RomFS'),('aoc',WORK/'aoc')]:
        assets[kind]={p.relative_to(directory).as_posix():p.stat().st_size for p in directory.rglob('*') if p.is_file()}
    save(gen/'dm/private-assets.json',assets)
    if args.embed_assets:
        for source,name in [(WORK/'game/RomFS','romfs'),(WORK/'aoc','aoc')]:
            subprocess.run(['cp','-cR',str(source),str(gen/name)],check=True)
    else:
        for name in ('romfs','aoc'):(gen/name).mkdir()
    if args.skin:
        # 触控皮肤（安卓 ui/skin 同款 key 集的游戏衍生位图）：用户自备目录 → Gen/skin（optional 资源，
        # 公开源码树不含——与 romfs 同纪律）；缺省不建目录，壳侧 DmTouchSkin 全量降级矢量/文字
        skin_src=Path(args.skin)
        if not skin_src.is_dir():sys.exit(f'[x] --skin 目录不存在：{skin_src}')
        shutil.copytree(skin_src,gen/'skin',dirs_exist_ok=True)
        print(f'[i] 触控皮肤 {len(list((gen/"skin").glob("*.png")))} 张 ← {skin_src}')
    subprocess.run(['xcodegen','generate','--spec',str(ios/'project.yml')],cwd=ios,env=settings,check=True)
    source_identity={str(p.relative_to(ROOT)):sha(p) for p in sorted((ios/'Sources').rglob('*')) if p.is_file()}
    compiled_inputs={str(p.resolve().relative_to(ROOT)):sha(p) for p in list((gen/'src').iterdir())+list((gen/'main').iterdir()) if p.is_file()}
    compiled_inputs['native/gamepad_mac.m']=sha(ROOT/'native/gamepad_mac.m')
    compiled_inputs['native/asset_inventory.h']=sha(ROOT/'native/asset_inventory.h')
    record=dict(schema=1,generated_at=time.time(),bundle_id=args.bundle_id,team_id=args.team_id,shader_chain=shaders['chain'],
                shader_receipt_sha256=sha(WORK/'shaders/ios-build.json'),rewrite=verified['artifacts'],graphics=graphics,
                source_files=source_identity,compiled_inputs=compiled_inputs,patch_sha256=sha(ROOT/'patches/nxnative.patch'),
                native_files=native_fingerprints(),app_icon=icon_receipt,
                signed_requested=args.sign,device=args.device,cpu=args.cpu,assets_embedded=args.embed_assets,
                limitations=['No runtime or device validation is implied by generation or compilation.'])
    if not args.generate_only:
        tag=str(time.time_ns())+('-signed' if args.sign else '-unsigned')
        log=WORK/'logs'/('build-ios-'+tag+'.log');log.parent.mkdir(exist_ok=True)
        command=['xcodebuild','-project',str(ios/'DR3MobileIOS.xcodeproj'),'-scheme','DR3Mobile','-configuration','Release',
                 '-destination','id='+args.device if args.device else 'generic/platform=iOS','-derivedDataPath',str(WORK/'build/ios')]
        command+=['-allowProvisioningUpdates','-allowProvisioningDeviceRegistration'] if args.sign else ['CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=']
        with log.open('w') as out:result=subprocess.run(command+['build'],env=settings,stdout=out,stderr=subprocess.STDOUT)
        shutil.copyfile(log,WORK/'logs/build-ios.log')
        for path,digest in compiled_inputs.items():
            if sha(ROOT/path)!=digest:raise RuntimeError('Source changed during iOS build; rebuild: '+path)
        for path,digest in source_identity.items():
            if sha(ROOT/path)!=digest:raise RuntimeError('Frontend changed during iOS build; rebuild: '+path)
        record.update(build_returncode=result.returncode,log=str(log),app=str(WORK/'build/ios/Build/Products/Release-iphoneos/DR3Mobile.app'))
        if not result.returncode:
            app=Path(record['app']);info=plistlib.loads((app/'Info.plist').read_bytes())
            if info['CFBundleIdentifier']!=args.bundle_id:raise ValueError('Built bundle identity differs')
            for key in ('CFBundleIcons','CFBundleIcons~ipad'):
                primary=info.get(key,{}).get('CFBundlePrimaryIcon',{})
                if primary.get('CFBundleIconName')!='AppIcon':raise ValueError('Built app icon missing: '+key)
                for name in primary.get('CFBundleIconFiles',[]):
                    if not list(app.glob(name+'*.png')):raise ValueError('Built icon pixels missing: '+name)
            if not (app/'Assets.car').is_file():raise ValueError('Compiled app icon catalog missing')
            for asset in (ios/'Sources/ControlArt').iterdir():
                if asset.is_file() and sha(app/'ControlArt'/asset.name)!=sha(asset):
                    raise ValueError('Built control artwork or provenance changed: '+asset.name)
            if info.get('MetalHUDEnabled') is not None:
                raise ValueError('HUD must follow startup selection, not a fixed Info.plist value')
            if '_dr3lan._udp' not in info.get('NSBonjourServices',[]):
                raise ValueError('Local network discovery service missing')
            binary=app/info['CFBundleExecutable'];record['executable_sha256']=sha(binary)
            record['platform_metadata']=subprocess.check_output(['xcrun','vtool','-show-build',str(binary)],text=True)
            if 'platform IOS' not in record['platform_metadata']:raise ValueError('Expected physical iOS executable')
            for name,digest in shaders['files'].items():
                if sha(app/'msl'/libs.name/name)!=digest:raise ValueError('Built shader resource changed: '+name)
        save(WORK/'build/ios/receipts'/(tag+'.json'),record)
        save(WORK/'ios-build-attempt.json',record)
        if result.returncode:raise RuntimeError('iOS build failed; '+str(log))
    save(WORK/('ios-generation.json' if args.generate_only else 'ios-build.json'),record)
    print(json.dumps(record,indent=2))


if __name__=='__main__':main()
