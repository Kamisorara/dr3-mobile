#!/usr/bin/env python3
"""H2O .ui layout parser (work in progress) — the data side of the HUD-relocation task.

Goal: read the compiled .ui files (deadbeef magic, inside ClientCommon.cpk), find the
position/anchor properties of HUD nodes (hp_bar / hotbar / minimap), so the relocation
can be done either by rewriting the file or — the chosen route — by patching the
runtime node tree at the same offsets.

Known structure so far (from ConsoleHUD.ui / ConsoleHUD_SinglePlayerFrame.ui):

  +0x00  u32 magic 0xDEADBEEF
  +0x04  u32 0x1e0                       # header size
  +0x08  u32 1                           # version?
  +0x0c  u32 checksum
  +0x10  u32 (larger than file size)     # meaning unknown (uncompressed size? string data size?)
  +0x14..+0x18 zeros
  +0x1c  u32 checksum 2
  +0x20  {u32 count?, u32 ?, u32 size?}  # 0xea / 0xb8 / 0x15060 in SinglePlayerFrame
  +0xd0  directory, 24-byte entries repeating: {u64 hash, u32 offset, u32 count}
         e.g. {0xec46311f_bc35acf3, 0x15118, 20}, {0x07b0a638_2325cc11, 0x15130, 73}
  ...    payload region (binary node structures with plaintext fragments)
  tail   string pool: entries of [u64 length][bytes], plus 32-bit file-offset pointers
         into it (0x68f0 -> the string that follows), node paths like
         "ConsoleHUD_main.LayoutRoot.hp_bar_template_player", "$anon$name" markers

Not yet understood: the node record layout (where x/y floats and anchors live), the
directory hash function, how entries reference the string pool.
"""
import struct
import sys
from pathlib import Path


def u64(d, o): return struct.unpack_from('<Q', d, o)[0]
def u32(d, o): return struct.unpack_from('<I', d, o)[0]


def summary(path):
    d = Path(path).read_bytes()
    magic, hsize, ver, ck1, big, z1, z2, ck2 = struct.unpack_from('<8I', d, 0)
    print(f'{Path(path).name}: {len(d)} bytes, header {hsize:#x}, ver {ver}, big={big:#x}')
    # directory walk: 24-byte entries from 0xd0 while offset/count look sane
    o = 0xd0
    n = 0
    while o + 24 <= len(d):
        h, off, cnt = struct.unpack_from('<QII', d, o)
        if off == 0 and cnt == 0:
            break
        if off >= len(d) or cnt > 0x10000:
            break
        print(f'  dir[{n}] hash={h:016x} off={off:#x} count={cnt}')
        o += 24
        n += 1
    # string pool sample: [u64 len][bytes] runs in the tail region
    pool = 0x15118 if len(d) > 0x15130 else len(d) // 2
    for i in range(6):
        ln = u64(d, pool)
        if not 1 <= ln <= 128:
            break
        s = d[pool + 8:pool + 8 + ln].split(b'\0')[0]
        print(f'  str @{pool:#x} len={ln}: {s.decode("utf-8", "replace")!r}')
        pool += 8 + ln + (-(ln) % 4)  # rough alignment guess
    return d


def find_paths(d, needle):
    """All occurrences of a (sub)string with surrounding raw bytes, for structure recon."""
    hits = []
    o = 0
    while (o := d.find(needle, o)) >= 0:
        hits.append(o)
        o += 1
    return hits


def main():
    for path in sys.argv[1:]:
        d = summary(path)
    if len(sys.argv) > 2:
        d = Path(sys.argv[1]).read_bytes()
        for needle in sys.argv[2:]:
            print(needle, [hex(x) for x in find_paths(d, needle.encode())])


if __name__ == '__main__':
    main()
