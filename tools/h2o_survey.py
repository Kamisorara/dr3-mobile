#!/usr/bin/env python3
"""Batch structural survey of the 397 compiled H2O .ui files (HUD-relocation recon).

Reads every .ui dumped from ClientCommon.cpk (_scratch/ui) and collects:
  * header fields across files (to pin constant vs variable fields)
  * directory-entry table shape ({hash64, offset, count} @24-byte stride?)
  * string-pool entry shape ([u64 length][bytes]?)
  * node-path references (32-bit file offsets pointing into the pool)
  * attribute-name and event-handler-name census
"""
import re
import struct
import sys
from collections import Counter
from pathlib import Path

UI = Path(__file__).resolve().parent.parent / '_scratch' / 'ui'


def u32(d, o): return struct.unpack_from('<I', d, o)[0]
def u64(d, o): return struct.unpack_from('<Q', d, o)[0]


def header_rows(d):
    return struct.unpack_from('<8I', d, 0)


def walk_dir(d, start=0xd0, max_entries=64):
    """24-byte {hash64, offset, count} entries until they stop looking sane."""
    rows = []
    o = start
    while o + 24 <= len(d) and len(rows) < max_entries:
        h, off, cnt = struct.unpack_from('<QII', d, o)
        if off == 0 and cnt == 0:
            break
        if off >= len(d) or cnt > 0x10000 or off < 0x20:
            break
        rows.append((h, off, cnt))
        o += 24
    return rows


def string_at(d, o):
    """Read a [u64 length][bytes] pool entry; returns (text, next_offset) or None."""
    if o + 8 > len(d):
        return None
    n = u64(d, o)
    if not 1 <= n <= 256:
        return None
    raw = d[o + 8:o + 8 + n]
    if len(raw) < n:
        return None
    txt = raw.split(b'\0')[0]
    try:
        txt.decode('ascii')
    except UnicodeDecodeError:
        return None
    return txt, o + 8 + n + (-(n) % 4)


def pool_probe(d, candidates):
    """Try each candidate offset; report the first that yields >=5 sane entries."""
    for base in candidates:
        o, got = base, []
        for _ in range(8):
            r = string_at(d, o)
            if not r:
                break
            got.append(r[0].decode())
            o = r[1]
        if len(got) >= 5:
            return base, got
    return None, []


def refs_to(d, target, lo=0, hi=None):
    """32-bit LE words equal to target (file-offset pointers)."""
    hi = hi or len(d)
    needle = struct.pack('<I', target)
    hits, o = [], lo
    while True:
        o = d.find(needle, o, hi)
        if o < 0:
            return hits
        hits.append(o)
        o += 1


def main():
    files = sorted(UI.glob('*.ui'))
    print(f'{len(files)} .ui files')
    hdr = Counter()
    dir_shapes = Counter()
    attr_names = Counter()
    event_names = Counter()
    hud_paths = {}
    for p in files:
        d = p.read_bytes()
        h = header_rows(d)
        hdr['magic'] += h[0] == 0xDEADBEEF
        hdr[f'hsize={h[1]:#x}'] += 1
        hdr[f'ver={h[2]}'] += 1
        rows = walk_dir(d)
        dir_shapes[len(rows)] += 1
        # attribute/event census from the whole file's ascii runs
        for m in re.finditer(rb'[A-Za-z_][A-Za-z0-9_]{5,48}', d):
            s = m.group()
            if s.endswith(b'_OnClick') or s.endswith(b'_OnButton') or s.endswith(b'_OnHotKey') or s.endswith(b'_OnRelease'):
                event_names[s.decode()] += 1
        for m in re.finditer(rb'(?<![a-z])(PositionOffset|Anchor[a-zA-Z]*|Size[a-zA-Z]*|Offset[a-zA-Z]*|Location[a-zA-Z]*|Rect[a-zA-Z]*)', d):
            attr_names[m.group(1).decode()] += 1
        # HUD element paths
        for pat, tag in ((rb'ConsoleHUD_main\.LayoutRoot\.[A-Za-z0-9_.]+', 'ConsoleHUD'),
                         (rb'Root\.NormalLayer\.[A-Za-z0-9_.]+', 'Root'),
                         (rb'[A-Za-z0-9_]*\.LayoutRoot\.[A-Za-z0-9_.]{2,60}', 'LayoutRoot')):
            if tag not in hud_paths:
                hud_paths[tag] = Counter()
            for m in re.finditer(pat, d):
                hud_paths[tag][m.group().decode()] += 1
    print('header magic ok:', hdr['magic'], '/', len(files))
    print('hsize values:', {k: v for k, v in hdr.items() if k.startswith('hsize')})
    print('dir-entry counts (entries per file):', dict(Counter(dir_shapes).most_common(8)))
    print('attribute names:', attr_names.most_common(20))
    print('event handlers:', len(event_names), 'unique; top 20:')
    for name, n in event_names.most_common(20):
        print(f'  {name} ×{n}')
    print('top LayoutRoot paths:')
    for path, n in hud_paths['LayoutRoot'].most_common(30):
        print(f'  {path} ×{n}')


if __name__ == '__main__':
    main()
