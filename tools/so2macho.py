#!/usr/bin/env python3
# 安卓 libd3rewrite.so → Mach-O 目标文件（.o）输出器（2026-11-10 .so 引擎直载轮，kb/07 §13）。
# 设计（完全照搬路线的基座）：安卓触控引擎的机器码原样执行，不做任何翻译——
#   1. 按 PT_LOAD 保留原虚拟地址布局输出 __TEXT(R+X) / __DATA(RW)（两段 RW 间空隙零填充，
#      ADRP 自相对寻址不受整体摆放位置影响）；
#   2. 233 个 PLT 桩改写为 `movz w17,#idx; b d3_plt_dispatch`（分发器附加在代码尾部，
#      经 __DATA 首槽 d3_shim_tab_ptr 拿宿主壳表——运行时宿主写一次指针，无重定位依赖）；
#   3. 标准 RELA 80 项：RELATIVE/无符号 ABS64 直接烧死加数；带符号 ABS64/GLOB_DAT 写入
#      d3_fixup_tab（运行时宿主按 偏移→壳符号 地址表补丁，__DATA 写合法）；
#   4. TPREL(TLS) 13 项不处理——不在触控调用路径（音频/视频引擎专用，风险已记 kb）；
#   5. 导出符号表（nlist64，C 前导下划线）随 .o 交付，宿主 `extern` 直链。
# 用法：python tools/so2macho.py <libd3rewrite.so> <out.o>
# | Convert the Android touch-engine .so into a linkable Mach-O object: preserve vaddr layout,
# | rewrite PLT stubs to an index dispatch trampoline, bake RELATIVE relocs, export symbols.
import struct, sys

def main():
    so_path, out_path = sys.argv[1], sys.argv[2]
    f = open(so_path, 'rb').read()

    # ---- ELF 头 / 程序头 ----
    e_phoff = struct.unpack_from('<Q', f, 0x20)[0]
    e_phentsize = struct.unpack_from('<H', f, 0x36)[0]
    e_phnum = struct.unpack_from('<H', f, 0x38)[0]
    loads = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        p_type, p_flags, p_off, p_vaddr, _, p_filesz, p_memsz, _ = struct.unpack_from('<IIQQQQQQ', f, o)
        if p_type == 1:
            loads.append(dict(off=p_off, vaddr=p_vaddr, filesz=p_filesz, memsz=p_memsz, flags=p_flags))
    loads.sort(key=lambda l: l['vaddr'])
    rx = next(l for l in loads if l['flags'] & 1)          # R+X（含 .text/.plt）
    rseg = loads[0]                                        # R（头部+dynsym+rodata 前段）
    rw = [l for l in loads if l['flags'] & 2]

    # ---- .dynamic 参数 ----
    e_shoff = struct.unpack_from('<Q', f, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', f, 0x3A)[0]
    e_shnum = struct.unpack_from('<H', f, 0x3C)[0]
    e_shstrndx = struct.unpack_from('<H', f, 0x3E)[0]
    def sh(i):
        o = e_shoff + i * e_shentsize
        v = struct.unpack_from('<IIQQQQIIQQ', f, o)
        return dict(name=v[0], typ=v[1], addr=v[3], off=v[4], size=v[5], link=v[6], entsize=v[9])
    st = sh(e_shstrndx)
    def sname(x):
        e = f.index(b'\0', st['off'] + x)
        return f[st['off'] + x:e].decode()
    secs = {}
    for i in range(e_shnum):
        s = sh(i)
        secs.setdefault(sname(s['name']), s)
    dyn = secs['.dynamic']
    d = {}
    o = dyn['off']
    while o < dyn['off'] + dyn['size']:
        tag, val = struct.unpack_from('<qQ', f, o); o += 16
        if tag == 0: break
        d.setdefault(tag, val)
    symtab_off, symtab_ent = d[6], d[11]
    strtab_off = d[5]
    rela_off, rela_sz = d[7], d[8]
    jmprel_off, jmprel_sz = d[0x17], d[0x22]
    arel_off, arel_sz = d.get(0x6fffe000, 0), d.get(0x6fffe001, 0)
    def symname(idx):
        o = symtab_off + idx * symtab_ent
        st_name = struct.unpack_from('<I', f, o)[0]
        e = f.index(b'\0', strtab_off + st_name)
        return f[strtab_off + st_name:e].decode()

    # ---- 壳符号清单（PLT 全集 ∪ 数据导入）----
    plt_syms = [symname(struct.unpack_from('<QQq', f, jmprel_off + i * 24)[1] >> 32)
                for i in range(jmprel_sz // 24)]
    all_syms = sorted(set(plt_syms) | set(symname(struct.unpack_from('<QQq', f, rela_off + i * 24)[1] >> 32)
                                          for i in range(rela_sz // 24)
                                          if struct.unpack_from('<QQq', f, rela_off + i * 24)[1] >> 32))
    # 安卓打包流解码（DT_ANDROID_REL：sleb128 offset-delta / info 对）
    android = []
    if arel_sz:
        data = f[arel_off:arel_off + arel_sz]
        pos = 0; prev = 0
        def sleb(buf, p):
            r = 0; shift = 0
            while True:
                b = buf[p]; p += 1
                r |= (b & 0x7f) << shift; shift += 7
                if not (b & 0x80): break
            if b & 0x40: r -= (1 << shift)
            return r, p
        while pos < len(data):
            dv, pos = sleb(data, pos); iv, pos = sleb(data, pos)
            prev += dv
            android.append((prev, iv))
        print(f'android packed rel: {len(android)} entries, types={sorted(set(i & 0xffffffff for _, i in android))}')

    # ---- 镜像总布局 ----
    lo = min(l['vaddr'] for l in loads)
    hi = max(l['vaddr'] + l['memsz'] for l in loads)
    img = bytearray(hi - lo)
    for l in loads:   # 文件内容按 vaddr 落位（off→vaddr 各段 delta 不同）
        img[l['vaddr'] - lo:l['vaddr'] - lo + l['filesz']] = f[l['off']:l['off'] + l['filesz']]
    RX_START, RX_END = rx['vaddr'] - lo, rx['vaddr'] - lo + rx['filesz']

    # ---- PLT 桩重写：movz w17,#idx; b d3_plt_dispatch ----
    # bionic PLT：PLT0（32B）+ PLTn（16B × N），PLTn i 对应 JMPREL 第 i 项
    plt_vaddr = secs['.plt']['addr'] - lo
    ent = secs['.plt']['entsize'] or 16
    plt0 = 32
    for i, sym in enumerate(plt_syms):
        ea = plt_vaddr + plt0 + i * ent
        if i >= 0x10000: die('PLT index overflow')
        img[ea:ea + 4] = struct.pack('<I', 0x52900000 | ((i & 0xffff) << 5))   # movz w17,#idx
        disp_off = RX_END                      # 分发器 = RX 内容尾部（后追加）
        rel = (disp_off - ea) >> 2
        assert -0x200000 <= rel < 0x200000, 'dispatch branch out of range'
        img[ea + 4:ea + 8] = struct.pack('<I', 0x14000000 | (rel & 0x03ffffff))  # b disp

    # ---- 标准 RELA：无符号烧死；带符号进运行时修复表 ----
    fixups = []   # (slot_vaddr_lo, shim_index_or_0xffffffff)
    baked = 0
    for i in range(rela_sz // 24):
        o = rela_off + i * 24
        r_off, r_info, r_add = struct.unpack_from('<QQq', f, o)
        t = r_info & 0xffffffff; s = r_info >> 32
        slot = r_off - lo
        if s == 0:   # RELATIVE(1027)/ABS64 内部：值 = 镜像内偏移加数，烧死
            struct.pack_into('<Q', img, slot, r_add & 0xffffffffffffffff)
            baked += 1
        else:        # GLOB_DAT/ABS64 外部：运行时按壳表补丁
            fixups.append((slot, all_syms.index(symname(s))))
    for off, info in android:   # 打包流：type 低 8 位，type 0/23（相对/绝对）烧死 info 载荷
        t = info & 0xff
        slot = off - lo
        if t in (0, 23) and 0 <= slot < len(img) - 7:
            struct.pack_into('<Q', img, slot, info >> 8 & 0xffffffffffffffff)
            baked += 1
        else:
            print(f'  android rel skipped: off={off:#x} type={t}')

    # ---- 分发器（追加到 RX 尾部，8 字节对齐）----
    disp_at = RX_END
    while disp_at % 8: disp_at += 1
    disp_code = bytes([
        0x11, 0x02, 0x40, 0xB9,   # ldr  w17, [x16]           ; w17 = tab_idx（movz 已带 idx）
        # ↑ 不对——PLT 桩里 movz 已把 idx 放 w17，分发器只需要拿表基址：
    ])
    # 分发器：
    #   adrp x16, d3_shim_tab_ptr        ; 镜像内自相对（__DATA 首槽）
    #   ldr  x16, [x16]                  ; x16 = 宿主壳表基址（宿主启动时写）
    #   ldr  x17, [x16, x17, lsl #3]     ; x17 = tab[idx]
    #   br   x17
    disp = []
    pc = disp_at
    def adrp(rd, target):
        off = target - pc
        imm = (off >> 12) & 0x1fffff
        return 0x90000000 | (imm & 3) << 29 | (imm >> 2) << 5 | rd
    def offlo(rd, base, imm):
        return 0xF9400000 | (imm >> 3) << 10 | base << 5 | rd      # ldr x, [x, #imm8*8]
    shim_ptr_vaddr = rw[0]['vaddr'] - lo            # __DATA 首槽 = 表指针
    disp.append(adrp(16, shim_ptr_vaddr))
    disp.append(offlo(16, 16, 0))
    disp.append(0xF8667B11 | (17 << 0))             # ldr x17,[x16,x17,lsl #3] = 0xF8667B11? 校正在下
    disp.append(0xD61F0000 | (17 << 5))             # br x17
    # ldr x17, [x16, x17, lsl #3] 编码：size=11 V=0 opc=01 → 0xF8600000 族，S=1 option=011(lsl #3)
    disp[2] = struct.pack('<I', 0xF8607A11 | (16 << 5) | (17 << 0))  # ldr x17,[x16,x17,lsl#3]
    for w in disp: img[disp_at:disp_at + 4] = struct.pack('<I', w); disp_at += 4
    disp_end = disp_at

    # ---- Mach-O 组装（MH_OBJECT 单节组）----
    MH_MAGIC_64 = 0xfeedfacf
    CPU_TYPE_ARM64 = 0x0100000C
    MH_OBJECT = 1
    # 节：__d3engine,__text（R+X 全镜像内容）+ __d3engine,__data（bss 零填充）
    text_data = bytes(img)
    bss_sz = 0   # bss 已在 img 尾部（memsz>filesz 段为零）——直接按初始化零携带，省 S_ZEROFILL 兼容问题
    n_sect = 2
    n_sym = 0
    secs_out = []
    # 布局：header + cmds | __text 数据 | __data(bss) 无数据 | symtab
    hdr_sz = 32 + (2 * 80 + 2 * 16 * 0) + 0   # header + 2 segment cmds…MH_OBJECT 用 LC_SEGMENT_64 每节一段或单段双节
    # 简化：单 LC_SEGMENT_64 双节
    sec_align = 12   # 4096
    text_off = (32 + 72 + 2 * 80 + 15) & ~15
    text_filesz = len(text_data)
    # __data 为零填充节（S_ZEROFILL 无文件内容）：大小 = RW 尾段 memsz（零页）
    data_sz = (rw[-1]['vaddr'] + rw[-1]['memsz']) - (rw[0]['vaddr'])
    seg_vaddr = rx['vaddr']
    seg_fileoff = 0
    # 仅一个文件节：__text；__data zerofill 虚拟存在
    total_file = text_off + text_filesz

    out = bytearray()
    out += struct.pack('<IIIIIIII', MH_MAGIC_64, CPU_TYPE_ARM64, MH_OBJECT, 0, 0,
                       32 + 72 + 2 * 80, 2 * 32, 0, 0)   # ncmds=2(段+符号表)? 先占位：段 1 条 + SYMTAB 1 条
    # 重写：ncmds = LC_SEGMENT_64 + LC_SYMTAB = 2
    out = bytearray(struct.pack('<IIIIIIII', MH_MAGIC_64, CPU_TYPE_ARM64, MH_OBJECT, 0, 0, 32 + 72 + 24, 2, 0, 0))
    # LC_SEGMENT_64 (0x19): cmdsize = 72 + 2*80
    cmd = bytearray()
    cmd += struct.pack('<II', 0x19, 72 + 2 * 80)
    cmd += b'__D3ENGINE'.ljust(16, b'\0')[:16]
    cmd += struct.pack('<QQQQiiii', seg_vaddr, seg_vaddr, seg_vaddr, seg_vaddr, 0, 0, 0, 0)  # 占位，下方回填
    cmd += struct.pack('<IIII', 4, 0, 0, 0)
    seg_cmd_at = len(out)
    out += cmd
    # section 头 ×2
    sect1_at = seg_cmd_at + 72
    sect2_at = sect1_at + 80
    # LC_SYMTAB (0x2)
    symtab_cmd_at = len(out)
    out += struct.pack('<IIIIII', 0x2, 24, 0, 0, 0, 0)
    # 文件头之后 → text 数据
    assert text_off >= len(out), 'header grew beyond text_off'
    sym_off = text_off + text_filesz

    def write_sect(at, name, segname, addr, size, off, align, flags):
        out[at:at + 80] = struct.pack('<16s16sQQiiIIIIQQ', name.ljust(16, b'\0')[:16], segname.ljust(16, b'\0')[:16],
                                      addr, size, off, align, 0 if size else 0, flags, 0, 0)
    # __text：整个镜像（含被改写的 PLT 与分发器）——文件内容 = text_data
    write_sect(sect1_at, b'__text', b'__D3ENGINE', seg_vaddr, text_filesz, text_off, sec_align, 0x80000400)  # S_ATTR_PURE_INSTRUCTIONS| SOME_MACHINE
    out[text_off:text_off + text_filesz] = text_data
    # __data zerofill：RW 全域零页（bss 语义）
    write_sect(sect2_at, b'__data', b'__D3ENGINE', rw[0]['vaddr'], data_sz, 0, sec_align, 1)  # S_ZEROFILL
    # 段命令回填：vmsize=file sz + zerofill，nsects=2
    vmsize = (data_sz + (rw[0]['vaddr'] - seg_vaddr) + 0xFFF) & ~0xFFF
    struct.pack_into('<QQQQiiii', out, seg_cmd_at + 24,
                     seg_vaddr, vmsize, seg_vaddr, text_filesz, text_filesz, 0, 0, 0)
    struct.pack_into('<I', out, seg_cmd_at + 64, 2)
    # 符号表：导出 d3_*（RX 段内符号）+ 镜像基准符号
    syms = []
    dynsym = secs['.dynsym']
    n = dynsym['size'] // dynsym['entsize']
    for i in range(n):
        o = dynsym['off'] + i * dynsym['entsize']
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from('<IBBHQQ', f, o)
        if st_shndx == 0 or not st_value: continue
        nm = symname(i)
        if not nm.startswith('d3_'): continue
        if not (rx['vaddr'] - lo <= st_value - lo < RX_END): continue
        syms.append((nm, st_value - lo, st_size))
    syms.append(('d3_image_start', rx['vaddr'] - lo, 0))
    nsyms = len(syms)
    strtab = bytearray(b'\0')
    symrec = bytearray()
    for nm, val, sz in syms:
        n_strx = len(strtab)
        strtab += ('_' + nm).encode() + b'\0'
        # nlist64: n_strx, n_type(STB_GLOBAL|N_SECT=0x0f), n_sect=1, n_desc, n_value
        symrec += struct.pack('<IBBHQ', n_strx, 0x0F, 1, 0, val)
    out += symrec
    out += strtab
    struct.pack_into('<IIIIII', out, symtab_cmd_at, 0x2, 24, sym_off + text_filesz, nsyms, sym_off + text_filesz + len(symrec))
    # 段文件的 ncmds 占位已写 2 ✓
    open(out_path, 'wb').write(bytes(out))
    print(f'emitted {out_path}: image {len(img)} bytes ({hex(lo)}..{hex(hi)}), '
          f'plt {len(plt_syms)} rewritten, rela baked {baked}, fixups {len(fixups)}, '
          f'symbols {nsyms}, android rel {len(android)}')
    # 修复表落盘（宿主 d3shim.c 生成用）
    with open(out_path + '.fixups.tsv', 'w') as fh:
        for slot, idx in fixups:
            fh.write(f'{slot:#x}\t{idx}\t{all_syms[idx]}\n')
    with open(out_path + '.shims.tsv', 'w') as fh:
        for i, s in enumerate(all_syms):
            fh.write(f'{i}\t{s}\n')

main()
