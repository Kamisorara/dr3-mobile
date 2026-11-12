"""Publication boundary checks using synthetic bytes only."""
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('audit_public',Path(__file__).resolve().parents[1]/'tools/audit_public.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)

class PublicAudit(unittest.TestCase):
    def test_private_content_paths_and_case(self):
        for path in ['ROMFS/anything.txt','platform/ios/Gen/env.txt','work/test.py','third_party/nxnative/source.c','game.NSP','x.cpk','x.metallib','cert.p12','.env.local']:
            self.assertIsNotNone(audit.path_error(path),path)
        self.assertIsNone(audit.path_error('native/asset_inventory.h'))

    def test_renamed_binary_and_lfs_are_rejected(self):
        for data in [b'NSO0'+bytes(40),b'PK\x03\x04'+bytes(40),b'version https://git-lfs.github.com/spec/v1\n',b'hello\0world']:
            self.assertIsNotNone(audit.content_error('innocent.txt',data))
        self.assertIsNone(audit.content_error('hello.py',b'print("hello")\n'))

    def test_replacing_reviewed_artwork_is_rejected(self):
        self.assertIsNotNone(audit.content_error(audit.ALLOWED_PNG,b'\x89PNG\r\n\x1a\nsynthetic'))
        p=Path(__file__).resolve().parents[1]/audit.ALLOWED_PNG
        self.assertIsNone(audit.content_error(audit.ALLOWED_PNG,p.read_bytes()))

    def test_reviewed_ci_snapshot_is_hash_pinned(self):
        # 快照 zip 豁免仅对钉死哈希的内容生效；换内容（哪怕同名）必须再被拒
        self.assertIsNone(audit.path_error(audit.ALLOWED_SNAPSHOT))
        self.assertIsNotNone(audit.content_error(audit.ALLOWED_SNAPSHOT,b'PK\x03\x04'+bytes(40)))
        p=Path(__file__).resolve().parents[1]/audit.ALLOWED_SNAPSHOT
        if p.exists():
            self.assertIsNone(audit.content_error(audit.ALLOWED_SNAPSHOT,p.read_bytes()))

    def test_credential_patterns_are_rejected_without_echo(self):
        value=b'header_key = '+b'0'*32
        reason=audit.content_error('config.txt',value)
        self.assertIsNotNone(reason)
        self.assertNotIn('0'*32,reason)

if __name__=='__main__':unittest.main()
