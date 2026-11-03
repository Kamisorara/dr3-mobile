#!/usr/bin/env python3
# 逐项打印 DMSH_CHAIN 各输入的 sha256（与 dmsh_chain.py version() 同口径），用于比对两台机器上链版本差异的来源。
# 用法：chain_debug.py   （环境与 dmsh_chain.py 相同：DM_GAME、DM_ROOT）
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NXN = os.path.join(HERE, '..', 'third_party', 'nxnative', 'dm', 'gfx', 'tools')
import importlib.util
spec = importlib.util.spec_from_file_location('dmsh_chain', os.path.join(NXN, 'dmsh_chain.py'))
dc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dc)

rows = []
h = hashlib.sha256()
for f in dc.FILES:
    p = os.path.join(dc.GFX, f)
    b = open(p, 'rb').read()
    rows.append((f, hashlib.sha256(b).hexdigest()[:16], len(b)))
    h.update(f.encode() + b'\0' + b + b'\0')
for f in dc.TABLES:
    b = dc.GAME.table(f).read_bytes()
    rows.append(('game/' + f, hashlib.sha256(b).hexdigest()[:16], len(b)))
    h.update(f'game/{f}'.encode() + b'\0' + b + b'\0')
game_rows = ''.join(f'{k}\t{chr(9).join(v)}\n' for k, v in dc.GAME.rows if k.startswith(('nvn_', 'shader_'))).encode()
rows.append(('game.tsv(nvn_/shader_)', hashlib.sha256(game_rows).hexdigest()[:16], len(game_rows)))
h.update(game_rows)
rows.append(('options', dc.options(), len(dc.options())))
h.update(dc.options().encode())
rows.append(('VERSION', h.hexdigest()[:12], 0))
for k, s, n in rows:
    print(f'{k}\t{s}\t{n}')
