#!/usr/bin/env python3
"""Audit actual Git blobs before source publication; never print secret values."""
import argparse
import hashlib
from pathlib import PurePosixPath
import re
import subprocess

FORBIDDEN_EXTENSIONS = set('cpk shd vsrc ttf icns jpg jpeg heic mov nsp nsz xci xcz nca tik cert keys nso nro npdm pfs0 hfs0 pkz pak bin img ctl code spv air metallib app ipa o dylib dll pdb p12 pfx pem key mobileprovision provisionprofile mp4 webm wav mp3 zip 7z rar log'.split())
PRIVATE_PARTS = {'.git', '.venv', 'work', 'romfs', 'exefs', 'shdump', 'shpack', 'save', 'gen', 'nxnative', '.impeccable'}
ALLOWED_PNG = 'platform/ios/Sources/ControlArt/dm_mobile_socket.png'
ALLOWED_PNG_SHA256 = '06492a002198c2a79353eeb60a953f2cebd5fead001c09e2ce6786226d69758b'
# CI 快照 zip（bootstrap 零下载，绝 GitHub API 403/404 根；bcada19 入库）：框架源码快照非私有内容，
# 秘密模式已全量扫描 0 命中。哈希钉死 = 内容一变审计即再报，同 ALLOWED_PNG 审查先例。
ALLOWED_SNAPSHOT = 'third_party/nxnative-s9579030.zip'
ALLOWED_SNAPSHOT_SHA256 = 'd8ad73fd8a1b2d59be3cdb2240ecf0f54ab8563f4c3964dde6060c102396bbe4'
MAGIC = (b'PFS0', b'HFS0', b'NSO0', b'NRO0', b'PK\x03\x04', b'\xcf\xfa\xed\xfe',
         b'\xce\xfa\xed\xfe', b'\x7fELF', b'\xca\xfe\xba\xbe', b'MZ')
SECRETS = (
    re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    re.compile(rb'\bgh[pousr]_[A-Za-z0-9]{30,}\b'),
    re.compile(rb'\bgithub_pat_[A-Za-z0-9_]{50,}\b'),
    re.compile(rb'\bAKIA[0-9A-Z]{16}\b'),
    re.compile(rb'(?m)^\s*(?:master_key_[0-9a-f]+|titlekek_[0-9a-f]+|header_key|key_area_key_[a-z0-9_]+)\s*=\s*[0-9a-fA-F]{32,}\s*$'),
)


def path_error(path):
    p = PurePosixPath(path)
    if any(part.lower() in PRIVATE_PARTS for part in p.parts):
        return 'private workspace/content path'
    if p.name.startswith('.env') and p.name != '.env.example':
        return 'local environment file'
    if p.suffix.lower().lstrip('.') in FORBIDDEN_EXTENSIONS:
        if str(p) != ALLOWED_SNAPSHOT:
            return 'private/generated file extension'
    return None


def content_error(path, data):
    if path == ALLOWED_SNAPSHOT:
        import hashlib as _h
        return None if _h.sha256(data).hexdigest() == ALLOWED_SNAPSHOT_SHA256 else 'reviewed CI snapshot zip content differs from pinned hash'
    if data.startswith(MAGIC) or data[0x200:0x204] in (b'NCA2', b'NCA3'):
        return 'executable/archive/game-container signature'
    if any(pattern.search(data) for pattern in SECRETS):
        return 'credential/key pattern (value redacted)'
    if data.startswith(b'version https://git-lfs.github.com/spec/v1'):
        return 'LFS pointer: source publication must not hide unchecked content'
    if path == ALLOWED_PNG and data.startswith(b'\x89PNG\r\n\x1a\n'):
        return None if hashlib.sha256(data).hexdigest() == ALLOWED_PNG_SHA256 else 'control artwork differs from reviewed MIT upstream asset'
    try:
        data.decode('utf-8')
    except UnicodeDecodeError:
        return 'unreviewed binary content'
    if b'\0' in data:
        return 'binary content in a source file'
    return None


def git(*args):
    return subprocess.check_output(['git', *args])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--all-history', action='store_true', help='Also scan every reachable historical blob')
    a = p.parse_args()
    blobs = set()
    errors = []
    entries = git('ls-files', '--stage', '-z').split(b'\0')
    for entry in filter(None, entries):
        meta, raw_path = entry.split(b'\t', 1)
        mode, oid, stage = meta.decode().split()
        path = raw_path.decode('utf-8')
        if mode not in ('100644', '100755') or stage != '0':
            errors.append((path, 'symlink/submodule/unmerged entry is not an audited source file'))
        blobs.add((oid, path))
    if not blobs:
        p.exit(1, 'Nothing staged/tracked; stage reviewed source files first\n')
    if a.all_history:
        for line in git('rev-list', '--objects', '--all').decode().splitlines():
            oid, _, path = line.partition(' ')
            if path:
                blobs.add((oid, path))
    # Ask Git for types/sizes before reading any potentially large private object.
    ordered = sorted(blobs)
    metadata = subprocess.run(['git', 'cat-file', '--batch-check'],
                              input=''.join(oid+'\n' for oid, _ in ordered).encode(),
                              capture_output=True, check=True).stdout.splitlines()
    selected = []
    for (oid, path), info in zip(ordered, metadata):
        fields = info.decode().split()
        if len(fields) != 3:
            errors.append((path, 'cannot inspect Git object'))
            continue
        if fields[1] != 'blob':
            continue
        reason = path_error(path)
        if reason:
            errors.append((path, reason))
        elif int(fields[2]) > 3 * 1024 * 1024 and path != ALLOWED_SNAPSHOT:
            errors.append((path, 'file exceeds reviewed source size limit'))
        else:
            selected.append((oid, path))
    reader = subprocess.Popen(['git', 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    total = 0
    try:
        for oid, path in selected:
            reader.stdin.write((oid+'\n').encode())
            reader.stdin.flush()
            header = reader.stdout.readline().split()
            size = int(header[2])
            data = reader.stdout.read(size)
            if len(data) != size or reader.stdout.read(1) != b'\n':
                raise RuntimeError('Truncated Git blob stream')
            total += size
            reason = content_error(path, data)
            if reason:
                errors.append((path, reason))
    finally:
        reader.stdin.close()
        reader.stdout.close()
        reader.wait()
    if reader.returncode:
        raise RuntimeError('Git blob reader failed')
    if errors:
        for path, reason in sorted(set(errors)):
            print(f'BLOCKED: {path}: {reason}')
        p.exit(1, f'Public-source audit failed: {len(set(errors))} findings. No secret values printed.\n')
    print(f'Public-source audit passed: {len(selected)} source blobs, {total / 1048576:.2f} MiB; '
          f'index{ " and all reachable history" if a.all_history else ""}.')


if __name__ == '__main__':
    main()
