// Private resource readiness: the pack wrote a manifest (path → exact byte size) of everything the
// game needs; the app checks every entry against the user's transferred copy. A failure reports
// enough to act on: how many files are missing, which ones, which root was expected, and what the
// transferred folder actually holds. Files Finder / Windows drop into transfers (.DS_Store, ._*
// AppleDouble, Thumbs.db, ...) never matter: the manifest is a whitelist, and diagnostics skip them
// when listing directories.
// 私有资源就绪检查：做包时写了一份清单（路径 → 精确字节数），App 逐项核对用户拷来的副本。失败时给出
// 能直接动手的信息：缺多少个、缺哪些、期望的根目录、拷来的文件夹里实际有什么。Finder / Windows 塞进
// 拷贝的杂物（.DS_Store、._* AppleDouble、Thumbs.db…）从不影响结果：清单是白名单，诊断列举时也跳过它们。
#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>

// 拷贝工具与系统塞进资源目录的杂物（诊断列举时跳过；白名单校验本来就不受它们影响）
// | Junk that transfer tools and the OS drop into resource folders (skipped by diagnostics; the
// | whitelist check is unaffected by them anyway)
static BOOL asset_junk(NSString *name) {
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@".Spotlight-V100", @".Trashes", @".fseventsd", @".TemporaryItems",
                 @".DocumentRevisions-V100", @".PKInstallSandboxManagerSystemSoftware", @"Thumbs.db",
                 @"desktop.ini", @"$RECYCLE.BIN", @"System Volume Information"]];
    });
    return name.length == 0 || [name isEqualToString:@".DS_Store"] || [name hasPrefix:@"._"] || [names containsObject:name];
}

// 顶层内容速览（过滤杂物，最多 max 个），诊断输出用 | top-level listing, junk filtered, capped at max
static NSArray *asset_top_entries(NSFileManager *fm, NSString *dir, NSUInteger max) {
    NSMutableArray *keep = [NSMutableArray array];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:dir error:nil])
        if (!asset_junk(entry) && keep.count < max) [keep addObject:entry];
    return keep;
}

static int assets_ready(NSString *directory, NSDictionary *inventory, NSString *kind) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![inventory isKindOfClass:NSDictionary.class] || !inventory.count || !directory) {
        fprintf(stderr, "boot: %s 的资源清单或位置缺失 | missing %s resource inventory/location\n", kind.UTF8String, kind.UTF8String);
        return 0;
    }
    NSString *root = directory.stringByResolvingSymlinksInPath;
    BOOL have_root = [fm fileExistsAtPath:root];
    NSMutableArray *missing = [NSMutableArray array];
    for (NSString *relative in inventory) {
        if (![relative isKindOfClass:NSString.class] || relative.isAbsolutePath || [relative.pathComponents containsObject:@".."] || ![inventory[relative] isKindOfClass:NSNumber.class]) {
            fprintf(stderr, "boot: %s 清单条目非法：%@ | bad %s manifest entry: %@\n", kind.UTF8String, relative, kind.UTF8String, relative);
            return 0;
        }
        NSString *path = [directory stringByAppendingPathComponent:relative].stringByResolvingSymlinksInPath;
        if (![path hasPrefix:[root stringByAppendingString:@"/"]]) {
            fprintf(stderr, "boot: %s 清单条目逃出根目录：%s | %s manifest entry escapes the root: %s\n",
                    kind.UTF8String, relative.UTF8String, kind.UTF8String, relative.UTF8String);
            return 0;
        }
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:nil];
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] != [inventory[relative] unsignedLongLongValue])
            [missing addObject:relative];
    }
    if (!missing.count) return 1;
    // 聚合输出：缺多少 / 缺哪些 / 期望的根 / 实际有什么——让用户一次就知道怎么修
    fprintf(stderr, "boot: %s 资源不完整：%lu / %lu 项缺失或大小不符（根目录：%s）| %s incomplete: %lu / %lu files missing or resized (root: %s)\n",
            kind.UTF8String, (unsigned long)missing.count, (unsigned long)inventory.count, root.UTF8String,
            kind.UTF8String, (unsigned long)missing.count, (unsigned long)inventory.count, root.UTF8String);
    for (NSString *m in [missing subarrayWithRange:NSMakeRange(0, MIN(6, (NSUInteger)missing.count))])
        fprintf(stderr, "boot:   缺 | missing %s\n", m.UTF8String);
    if ((NSUInteger)missing.count > 6) fprintf(stderr, "boot:   …等共 %lu 项 | …and %lu more\n", (unsigned long)missing.count, (unsigned long)missing.count - 6);
    if (!have_root) {
        fprintf(stderr, "boot: 根目录不存在：把 %s 文件夹整个拷进 Documents（保持原名）| the root folder is absent: copy the %s folder into Documents, keeping its name\n",
                kind.UTF8String, kind.UTF8String);
    } else {
        NSArray *entries = asset_top_entries(fm, root, 6);
        fprintf(stderr, "boot: 根目录顶层实际有 %lu 项 | the root actually holds %lu entries:", (unsigned long)entries.count, (unsigned long)entries.count);
        for (NSString *e in entries) fprintf(stderr, " %s", e.UTF8String);
        fprintf(stderr, "\n");
    }
    return 0;
}
