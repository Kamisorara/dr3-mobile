#!/usr/bin/env python3
"""patches/nxnative.patch 整体重生成（受限 41 文件集；zip 原始 vs 工作区终版）。

修复 2026-11-10 发现的补丁漂移：历史上只重生成过个别节，工作树另有 23 个文件
（controller_effects/dm_input_clear/HID receipt 等）领先补丁——出包走工作树所以没炸，
但公开树（zip+patch）复现出的源码与实际出包不一致。

规则：
  - 节集合与顺序 = 现补丁的 41 个文件（不新增 games TSV / ghidra 工具 / bin/obj 产物）；
  - 每节 = zip 原始字节（无则 new file）vs 工作区字节（LF 归一、补尾换行）；
  - 补丁文件整体 LF；index 行 = 真实 blob sha1。
用法：python -I tools/regen_nx_patch.py [--check]
  --check 只做校验不写回（zip+现补丁 vs 工作区，EOL 归一比对）。
"""
import difflib
import hashlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PATCH = ROOT / 'patches/nxnative.patch'
ZIP = ROOT / 'third_party/nxnative-s9579030.zip'
UP = ROOT / 'third_party/nxnative'


def norm(b: bytes) -> bytes:
    b = b.replace(b'\r\n', b'\n')
    if b and not b.endswith(b'\n'):
        b += b'\n'
    return b


def blob(b: bytes) -> str:
    return hashlib.sha1(b'blob %d\x00' % len(b) + b).hexdigest()[:7]


def load_patch_paths(patch_bytes: bytes):
    paths = []
    for line in patch_bytes.decode('utf-8', errors='replace').splitlines():
        if line.startswith('diff --git a/'):
            paths.append(line.split(' b/', 1)[0][len('diff --git a/'):])
    return paths


def section(path: str, zbytes: bytes | None, wbytes: bytes | None) -> bytes | None:
    """一个文件的 git 风格 diff 节；无差异返回 None；工作树缺文件 → 删除节。"""
    if wbytes is None:
        if zbytes is None:
            return None
        out = [f'diff --git a/{path} b/{path}', 'deleted file mode 100644',
               f'index {blob(zbytes)}..0000000', f'--- a/{path}', '+++ /dev/null',
               f'@@ -1,{len(zbytes.splitlines())} +0,0 @@']
        out += ['-' + l for l in zbytes.decode('utf-8', errors='replace').splitlines()]
        return ('\n'.join(out) + '\n').encode()
    wbytes = norm(wbytes)
    if zbytes is None:
        lines = wbytes.decode('utf-8', errors='replace').splitlines()
        out = [f'diff --git a/{path} b/{path}', 'new file mode 100644',
               f'index 0000000..{blob(wbytes)}', '--- /dev/null', f'+++ b/{path}',
               f'@@ -0,0 +1,{len(lines)} @@']
        out += ['+' + l for l in lines]
        return ('\n'.join(out) + '\n').encode()
    zbytes = norm(zbytes)
    if zbytes == wbytes:
        return None
    a = zbytes.decode('utf-8', errors='surrogateescape').splitlines()
    b = wbytes.decode('utf-8', errors='surrogateescape').splitlines()
    body = difflib.unified_diff(a, b, n=3, lineterm='')
    out = [f'diff --git a/{path} b/{path}',
           f'index {blob(zbytes)}..{blob(wbytes)} 100644',
           f'--- a/{path}', f'+++ b/{path}']
    out += list(body)[2:]  # 跳过 difflib 自带的 ---/+++
    return ('\n'.join(out) + '\n').encode('utf-8', errors='surrogateescape')


def main():
    check_only = '--check' in sys.argv
    zf = zipfile.ZipFile(ZIP)
    znames = set(n for n in zf.namelist() if not n.endswith('/'))
    patch_bytes = PATCH.read_bytes()
    paths = load_patch_paths(patch_bytes)

    parts = []
    dropped, missing_work = [], []
    for p in paths:
        zbytes = zf.read(p) if p in znames else None
        wp = UP / p
        wbytes = wp.read_bytes() if wp.exists() else None
        if wbytes is None and zbytes is not None:
            missing_work.append(p)
        sec = section(p, zbytes, wbytes)
        if sec is None:
            dropped.append(p)   # 工作区与 zip 相同：节消失（正常极少）
            continue
        parts.append(sec)

    if missing_work:
        sys.exit('[x] 工作树缺文件（删除节需人工确认）：%s' % missing_work)
    newp = b''.join(parts)
    print('sections in=%d out=%d dropped=%s' % (len(paths), len(parts), dropped or '-'))
    if check_only:
        cur = norm(patch_bytes)
        gen = norm(newp)
        print('current == regenerated: %s' % (cur == gen))
        return
    PATCH.write_bytes(newp)
    print('patch written: %d bytes' % len(newp))


if __name__ == '__main__':
    main()
