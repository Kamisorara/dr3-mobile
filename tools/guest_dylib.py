#!/usr/bin/env python3
# 把改写后的模块映像写成一个苹果格式的动态库 Guest.framework/Guest：只装段，没有符号，没有代码之外的任何东西。
# 只用 Python 标准库，不调用编译器、链接器或任何苹果工具，在 macOS / Linux / Windows 上产出逐字节相同的文件。
# 给谁用：壳安装包（tools/shell_build.py 出）不含游戏程序；使用者用自己的游戏文件改写出模块映像后，由 tools/dr3_pack.py 调本脚本
# 写出这个库、放进安装包的 Frameworks/，再用自签工具整包签名。宿主的装载器（dm/host/loader.c，映像头由 platform/ios/Sources/main.m 的
# DM_SHELL 分支经 dm_set_game_image_header 提供）按节名取段。
# 节的布局与内嵌做法（nxnative dm/ios/tools/gen_embed.py）一致，装载器不用分两套（含 back patch 区与 patch 区在基址前的 FAR 布局）：
#   __TEXT,__dm<名>x0   原 text：[0, 圆整16K(TEXT_END))
#   __DM<名>W,__img     可写段：[圆整16K(TEXT_END), PATCH_OFF)（FAR：到 FILE_IMAGE_LEN 为止）
#   __TEXT,__dm<名>x1   补丁区：[PATCH_OFF, 圆整16K(文件尾))（FAR：[FILE_IMAGE_LEN, 圆整16K(尾)-BACK_LEN)）
#   __TEXT,__dm<名>x2   仅有 back patch 区时（BACK_LEN）：文件最后 BACK_LEN 字节
# 文件格式上要注意的三点（d2r-mobile 在真机 / Mac 上实测得出的，照搬）：
#   · 必须声明依赖 /usr/lib/libSystem.B.dylib，否则系统拒绝加载（「must link with at least libSystem.dylib」）；
#   · 每个节按 16K 对齐、整页大小：装载器用 vm_remap 按整页取；
#   · __LINKEDIT 放在最后，末尾留一块预留的代码签名区，里面是链接器式的自签（CS_LINKER_SIGNED），空间充裕，重签工具可原地写入自己的签名；
#     zsign（LiveContainer 等设备端签名器）没法给这个文件新增签名命令，因为它只靠名为 __text 的节找装载命令的空闲空间，而 Guest 没有这个节。
# 用法：guest_dylib.py <产物目录> <输出目录> <模块名...>     输出 <输出目录>/Guest.framework/{Guest,Info.plist}
import hashlib, os, struct, sys

PG = 0x4000
MIN_IOS = 26 << 16   # 与工程的最低系统版本一致（platform/ios/project.yml deploymentTarget）


def r16(x): return (x + PG - 1) & ~(PG - 1)


def s16(s):
    b = s.encode(); assert len(b) <= 16, s; return b.ljust(16, b'\0')


def segment(name, addr, size, fileoff, filesize, prot, sects):
    b = struct.pack('<II16sQQQQiiII', 0x19, 72 + 80 * len(sects), s16(name), addr, size, fileoff, filesize, prot, prot, len(sects), 0)
    for sn, a, sz, flags in sects:
        b += struct.pack('<16s16sQQIIIIIIII', s16(sn), s16(name), a, sz, a, 14, 0, 0, flags, 0, 0, 0)   # 文件偏移 = 地址；对齐 2^14
    return b


def dylib_cmd(cmd, name):
    name += b'\0' * (8 - len(name) % 8)
    return struct.pack('<IIIIII', cmd, 24 + len(name), 24, 2, 0x10000, 0x10000) + name


def adhoc_sig(data, text_size):
    # 苹果 cs_blobs.h 的 SuperBlob + CodeDirectory 0x20400，SHA-256 页哈希；用链接器式（CS_LINKER_SIGNED），重签工具不用强制标志就能替换它
    n = (len(data) + 4095) // 4096; ident = b'Guest\0'; hdr = struct.calcsize('>IIIIIIIIIBBBBIIIIQQQQ'); assert hdr == 88
    cd = struct.pack('>IIIIIIIIIBBBBIIIIQQQQ', 0xfade0c02, hdr + len(ident) + 32 * n, 0x20400, 0x20002, hdr + len(ident), hdr, 0, n, len(data), 32, 2, 0, 12, 0, 0, 0, 0, 0, 0, text_size, 0)
    cd += ident + b''.join(hashlib.sha256(data[i:i + 4096]).digest() for i in range(0, len(data), 4096))
    return struct.pack('>IIIII', 0xfade0cc0, 20 + len(cd), 1, 0, 20) + cd


def pieces(out, n):
    """一个模块的 (映像字节, [(节名, 起, 止)…])，节顺序 = x0, W, x1[, x2]；与 gen_embed.py 的 pieces() 同一算法。"""
    hdr = dict(l[2:].split() for l in open(os.path.join(out, n + '.fixups.tsv')) if l.startswith('# '))
    te, po = int(hdr['TEXT_END'], 16), int(hdr['PATCH_OFF'], 16)
    ko, ks = int(hdr['KEY_PAGE_OFF'], 16), int(hdr['KEY_PAGE_SIZE'], 16)
    img = open(os.path.join(out, n + '.patched.bin'), 'rb').read(); sz = len(img)
    a, end = r16(te), r16(sz)
    if po < 0:   # 补丁区在基址前（patch_nso.py FAR）：W 到数据尾为止，bss 与键页由装载器给零页；文件里补丁区在 FILE_IMAGE_LEN 之后
        fl, bl = int(hdr['FILE_IMAGE_LEN'], 16), int(hdr.get('BACK_LEN', '0'), 16)
        assert fl % PG == 0 and a <= fl and ko % PG == 0 and ks == PG and ko >= fl and bl % PG == 0 and (not bl or sz % PG == 0), (n, hex(te), hex(po), hex(sz))
        parts = ((0, a), (a, fl), (fl, end - bl)) + (((end - bl, end),) if bl else ())
    else:
        assert po % PG == 0 and a <= ko and ko + ks <= po and ko % PG == 0 and ks == PG, (n, hex(te), hex(po), hex(sz))
        parts = ((0, a), (a, po), (po, end))
    names = ('__dm%sx0' % n, '__img', '__dm%sx1' % n, '__dm%sx2' % n)
    return img, list(zip(names, [(lo, hi) for lo, hi in parts]))


def build(out, names):
    text, wsegs = [], []
    for n in names:
        img, parts = pieces(out, n); sz = len(img)
        cut = lambda lo, hi: img[lo:min(hi, sz)].ljust(hi - lo, b'\0')
        for sn, (lo, hi) in parts:
            b = cut(lo, hi)
            if sn == '__img': wsegs.append(('__DM%sW' % n, b))
            else: text.append((sn, b))
    off = PG; tsects = []; body = b''          # 第一页：文件头与装载命令
    for sn, b in text:
        tsects.append((sn, off, len(b), 0x80000400)); body += b; off += len(b)   # 纯指令节
    cmds = [segment('__TEXT', 0, off, 0, off, 5, tsects)]; tsz = off
    for sn, b in wsegs:
        cmds.append(segment(sn, off, len(b), off, len(b), 3, [('__img', off, len(b), 0)])); body += b; off += len(b)
    strtab = b'\0' * 8
    cs_off = (off + len(strtab) + 15) & ~15; cs_size = (((cs_off // 4096 + 1) * 52 + 4095) & ~4095) + 0x40000   # 签名区：16 字节对齐；留足 SHA-1 + SHA-256 页哈希（52 字节/页）外加 256K
    uuid = hashlib.sha256(body).digest()[:16]   # 由内容定：同样的输入在哪台机器上出的库都逐字节相同
    cmds += [segment('__LINKEDIT', off, r16(cs_off + cs_size - off), off, cs_off + cs_size - off, 1, []),
             dylib_cmd(0xd, b'@rpath/Guest.framework/Guest'),                    # LC_ID_DYLIB
             struct.pack('<II10I', 0x80000022, 48, *([0] * 10)),                 # LC_DYLD_INFO_ONLY：没有重定位、没有绑定、没有导出
             struct.pack('<IIIIII', 0x2, 24, off, 0, off, len(strtab)),          # LC_SYMTAB：0 个符号
             struct.pack('<II18I', 0xb, 80, *([0] * 18)),                        # LC_DYSYMTAB
             struct.pack('<II16s', 0x1b, 24, uuid),                              # LC_UUID
             struct.pack('<IIIIII', 0x32, 24, 2, MIN_IOS, MIN_IOS, 0),           # LC_BUILD_VERSION：平台 2 = iOS
             dylib_cmd(0xc, b'/usr/lib/libSystem.B.dylib'),                      # LC_LOAD_DYLIB
             struct.pack('<IIII', 0x1d, 16, cs_off, cs_size)]                    # LC_CODE_SIGNATURE：放在最后一条，与 ld 一致
    lc = b''.join(cmds); assert 32 + len(lc) <= PG
    mh = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 6, len(cmds), len(lc), 0x00100085, 0)   # arm64、动态库
    data = ((mh + lc).ljust(PG, b'\0') + body + strtab).ljust(cs_off, b'\0')
    return (data + adhoc_sig(data, tsz)).ljust(cs_off + cs_size, b'\0')   # 签名覆盖 [0, cs_off)


INFO_PLIST = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Guest</string>
<key>CFBundleIdentifier</key><string>%s</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>Guest</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>26.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
'''


def write(out, dst, names, bundle_id='local.guest'):
    fw = os.path.join(dst, 'Guest.framework'); os.makedirs(fw, exist_ok=True)
    data = build(out, names)
    with open(os.path.join(fw, 'Guest'), 'wb') as f: f.write(data)
    with open(os.path.join(fw, 'Info.plist'), 'w', encoding='utf-8', newline='\n') as f: f.write(INFO_PLIST % bundle_id)
    return fw, len(data)


if __name__ == '__main__':
    if len(sys.argv) < 4: sys.exit(__doc__.splitlines()[0])
    fw, n = write(sys.argv[1], sys.argv[2], sys.argv[3:])
    print('Guest.framework: %d bytes, modules %s' % (n, ', '.join(sys.argv[3:])))
