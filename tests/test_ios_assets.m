#import <Foundation/Foundation.h>
#include "../native/asset_inventory.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"11"] withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *file=[root stringByAppendingPathComponent:@"11/sample.cpk"];
    assert([[@"payload" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file atomically:YES]);
    NSDictionary *expected=@{@"11/sample.cpk":@7};
    // 拷贝工具塞的杂物与白名单校验共存：.DS_Store / AppleDouble / Thumbs.db 不影响结果
    assert([[NSString stringWithFormat:@"x"] writeToFile:[root stringByAppendingPathComponent:@".DS_Store"] atomically:YES]);
    assert([[NSString stringWithFormat:@"x"] writeToFile:[root stringByAppendingPathComponent:@"._sample.cpk"] atomically:YES]);
    assert([[NSString stringWithFormat:@"x"] writeToFile:[root stringByAppendingPathComponent:@"Thumbs.db"] atomically:YES]);
    assert(assets_ready(root,expected,@"test"));
    assert(!assets_ready(root,@{@"11/sample.cpk":@8},@"truncated"));
    assert(!assets_ready(root,@{@"11/absent.cpk":@0},@"absent"));
    assert(!assets_ready(root,@{@"11":@0},@"directory"));
    assert(!assets_ready(root,@{@"../outside":@7},@"parent"));
    assert(!assets_ready(root,@{@"/absolute":@7},@"absolute"));
    assert(!assets_ready(root,@{@"11/sample.cpk":@"7"},@"untyped"));
    assert(!assets_ready(root,@{},@"empty"));
    // 垃圾文件名判定：拷贝工具的常见产物都算
    assert(asset_junk(@".DS_Store") && asset_junk(@"._icon.png") && asset_junk(@"Thumbs.db") && asset_junk(@"desktop.ini"));
    assert(!asset_junk(@"CoreCommon.cpk") && !asset_junk(@".gitkeep"));
    // 多项缺失：聚合输出（只验证不炸与返回值；详情走 stderr）
    assert(!assets_ready(root,@{@"11/a.data":@1,@"11/b.data":@2,@"11/c.data":@3},@"multi-missing"));
    NSString *outside=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([[@"payload" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:outside atomically:YES]);
    assert([fm createSymbolicLinkAtPath:[root stringByAppendingPathComponent:@"link"] withDestinationPath:outside error:nil]);
    assert(!assets_ready(root,@{@"link":@7},@"escaped symlink"));
    assert([fm removeItemAtPath:outside error:nil]);
    assert([fm removeItemAtPath:root error:nil]);
    puts("PASS: complete private resources, partial/absent files, path confinement and typed manifests");
} return 0; }
