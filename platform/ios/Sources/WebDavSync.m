// WebDavSync.m — DR3 Mobile 的 WebDAV 云存档同步（dr3-webdav v1，内置宿主）
// | WebDAV cloud-save sync for DR3 Mobile (built into the iOS host).
//
// 移植自 d2r-webdav（d2rwebdav.m，D2R Mobile 真机验证过的实现），适配 DR3 的事务式存档
// （third_party/nxnative/dm/host/hle_fs.c）：
//   · 存档事务：游戏只写 <save>.work，Commit 时整树原子换入已提交目录（$DM_SAVE = Documents/save）。
//     本模块只碰已提交目录——它只在 Commit 时整目录原子变化，扫到的永远是完整快照；
//     save.work / save.new 是兄弟目录，天然不可见。
//   · 启动下拉：dm_webdav_boot_start()（main.m startMode，用户点「开始」时）起线程取云端 manifest，
//     按单元修改时间比较（新者赢）；dm_webdav_wait_boot()（main.m front_ios_boot，spawn dm_main 前）
//     等待完成或硬超时（默认 5 秒，到点即弃，绝不装一半）。游戏在 dm_main 里才 MountSaveData，
//     下拉与挂载绝无竞争；窗口过后本模块本次运行绝不再写本地存档。
//   · 推送触发：g_dm_save_commit_hook（hle_fs.c 提交成功即回调；持锁调用，这里只做原子标志 +
//     信号量唤醒，不做任何 IO）→ 游戏自动保存后立刻打包上传；常驻轮询（默认 2 秒）兜住不经
//     Commit 的直写（hle_season.c 的 dm-season-heroes.tsv），防抖 3 秒；切后台立即推送。
//   · 同步单元 = 整个 Documents/save（单单元 "save"）：D3 存档跨文件一致（account/profile/英雄文件
//     互相配套），事务提交整目录原子，端到端保持原子性；不做墓碑删除（pack 的 deleted 位保留做
//     前向兼容，读到即视为无效包）。
//   · 无配置零动作：Documents/webdav.json 不存在或 enabled:false → 不起线程、不注册 hook、零开销。
//
// pack 格式（自定义、无压缩、小端）：
//   "D3W1" | u32 flags（bit0=已删标记，DR3 永不写入）| u32 count |
//   每项：u32 路径字节数 | 路径 UTF-8（相对 save 根，'/' 分隔）| u64 mtime 毫秒 | u64 字节数 | 数据
// 云端布局（cfgDir 之下）：manifest.json + packs/save.pack。
// WebDAV 细节（d2r-webdav 真机经验照搬）：MKCOL 父先子后；PUT 409/404 补建目录链重试一次；
// 503/429（坚果云限速）10/30/90 秒退避；manifest 只记真正传成功的。
//
// 比 d2r-webdav v1 多一道防倒退守卫：每次推送前重新取云端 manifest，若云端单元比本机上次同步视图
// 新、也比本机当前档新（别的设备推过更进的进度）→ 跳过本次 PUT，留给下次启动下拉对齐——
// 防「下拉失败 → 陈旧补推覆盖云端新档」。另修了 v1 的补推失效：本地新于云端时不再改写 state
// （保留待推送标记），上次没传完的档启动后会被「启动补推」真正推上去。

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>      // renamex_np / RENAME_SWAP（与 hle_fs.c 的存档提交同款原子互换）
#include <errno.h>
#include <string.h>

#define DW_VER  @"1.0.0"
#define DW_UNIT @"save"          // 唯一同步单元：整个已提交存档目录
#define DW_MAGIC "D3W1"

// hle_fs.c 的存档提交钩子（提交成功后以已提交目录调用；本文件在 boot_start 里登记自己的实现）
extern void (*g_dm_save_commit_hook)(const char *commit_dir);

// ---------- 路径（boot_start 里一次定死；日志路径就位之前 dw_log 只走 NSLog） ----------
static NSString *g_docDir, *g_saveDir, *g_stateDir, *g_backupDir, *g_tmpDir, *g_stateFile, *g_deviceId;
static NSString *g_logPath;

// ---------- 对外接口（main.m 三处调用） ----------
void dm_webdav_boot_start(void);                 // startMode：读配置，起了下拉线程就返回
void dm_webdav_wait_boot(void);                  // front_ios_boot：等下拉完成或硬超时，再放行 dm_main
void dm_webdav_push_now(const char *why);        // 切后台等外部触发：立即推送

// ---------- 日志（NSLog + Documents/webdav.log，超 200KB 砍掉前一半） ----------
static NSLock *g_logLock;

static void dw_log(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[dr3-webdav] %@", msg);
    if (!g_logPath) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_logLock = [[NSLock alloc] init]; });
    [g_logLock lock];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:g_logPath])
            [@"" writeToFile:g_logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
        if (h) {
            [h seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
            [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
        NSDictionary *at = [fm attributesOfItemAtPath:g_logPath error:nil];
        if ([at fileSize] > 200 * 1024) {
            NSData *d = [NSData dataWithContentsOfFile:g_logPath];
            if (d.length > 100 * 1024) {
                [[d subdataWithRange:NSMakeRange(d.length - 100 * 1024, 100 * 1024)]
                    writeToFile:g_logPath atomically:YES];
            }
        }
    } @catch (id e) {
    }
    [g_logLock unlock];
}

static uint64_t dw_now_ms(void) { return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000); }

// ---------- 配置（Documents/webdav.json，文件共享开着，「文件」App 里改，重启生效） ----------
static NSString *g_cfgUrl, *g_cfgUser, *g_cfgPass, *g_cfgDir, *g_authHeader;
static BOOL g_cfgEnabled;
static double g_cfgBootTimeout = 5.0, g_cfgPoll = 2.0, g_cfgDebounce = 3.0;

static NSDictionary *dw_load_config(void) {
    NSString *p = [g_docDir stringByAppendingPathComponent:@"webdav.json"];
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) return nil;
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:&err];
    if (err || ![obj isKindOfClass:[NSDictionary class]]) {
        dw_log(@"配置解析失败：%@", err.localizedDescription);
        return nil;
    }
    return obj;
}

static BOOL dw_config_apply(NSDictionary *cfg) {
    NSString *url = cfg[@"url"];
    if (![url isKindOfClass:[NSString class]] || !([url hasPrefix:@"https://"] || [url hasPrefix:@"http://"])) {
        dw_log(@"配置缺 url（需 http(s):// 开头），同步停用");
        return NO;
    }
    g_cfgUrl = url;
    g_cfgUser = [cfg[@"user"] isKindOfClass:[NSString class]] ? cfg[@"user"] : @"";
    g_cfgPass = [cfg[@"pass"] isKindOfClass:[NSString class]] ? cfg[@"pass"] : @"";
    g_cfgDir  = [cfg[@"dir"]  isKindOfClass:[NSString class]] ? cfg[@"dir"] : @"dr3-saves";
    NSNumber *en = cfg[@"enabled"];
    g_cfgEnabled = en ? [en boolValue] : YES;
    NSNumber *bt = cfg[@"boot_timeout"], *pi = cfg[@"poll_interval"], *db = cfg[@"debounce"];
    if (bt) g_cfgBootTimeout = MAX(1.0, [bt doubleValue]);
    if (pi) g_cfgPoll = MAX(0.5, [pi doubleValue]);
    if (db) g_cfgDebounce = MAX(0.5, [db doubleValue]);
    if (g_cfgUser.length) {
        NSData *b = [[NSString stringWithFormat:@"%@:%@", g_cfgUser, g_cfgPass]
                     dataUsingEncoding:NSUTF8StringEncoding];
        g_authHeader = [NSString stringWithFormat:@"Basic %@",
                        [b base64EncodedStringWithOptions:0]];
    }
    return YES;
}

// ---------- pack 格式（小端，全部显式编码，不依赖本机字节序） ----------
static void dw_put32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) };
    [d appendBytes:b length:4];
}
static void dw_put64(NSMutableData *d, uint64_t v) {
    uint8_t b[8] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24),
                     (uint8_t)(v >> 32), (uint8_t)(v >> 40), (uint8_t)(v >> 48), (uint8_t)(v >> 56) };
    [d appendBytes:b length:8];
}

typedef struct { const uint8_t *p; NSUInteger n, off; int ok; } dw_rdr;
static uint32_t dw_r32(dw_rdr *r) {
    if (r->off + 4 > r->n) { r->ok = 0; return 0; }
    const uint8_t *b = r->p + r->off; r->off += 4;
    return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24;
}
static uint64_t dw_r64(dw_rdr *r) {
    if (r->off + 8 > r->n) { r->ok = 0; return 0; }
    const uint8_t *b = r->p + r->off; r->off += 8; uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = v << 8 | b[i];
    return v;
}
static const uint8_t *dw_rbytes(dw_rdr *r, NSUInteger len) {
    if (r->off + len > r->n) { r->ok = 0; return NULL; }
    const uint8_t *b = r->p + r->off; r->off += len; return b;
}

@interface DWPackEntry : NSObject
@property (copy) NSString *path;    // 相对 save 根，'/' 分隔
@property uint64_t mtime;           // 毫秒
@property uint64_t size;
@property (strong) NSData *data;    // 扫描时不读，打包时才读
@end
@implementation DWPackEntry
@end

static NSData *dw_pack_build(NSArray<DWPackEntry *> *entries) {
    NSMutableData *d = [NSMutableData data];
    [d appendBytes:DW_MAGIC length:4];
    dw_put32(d, 0);                                   // flags：DR3 永不写删除标记
    dw_put32(d, (uint32_t)entries.count);
    for (DWPackEntry *e in entries) {
        NSData *path = [e.path dataUsingEncoding:NSUTF8StringEncoding];
        dw_put32(d, (uint32_t)path.length);
        [d appendData:path];
        dw_put64(d, e.mtime);
        dw_put64(d, e.size);
        [d appendData:e.data ?: [NSData data]];
    }
    return d;
}

static NSArray<DWPackEntry *> *dw_pack_parse(NSData *pack) {
    dw_rdr r = { .p = (const uint8_t *)pack.bytes, .n = pack.length, .off = 0, .ok = 1 };
    const uint8_t *magic = dw_rbytes(&r, 4);
    if (!r.ok || memcmp(magic, DW_MAGIC, 4)) return nil;
    uint32_t flags = dw_r32(&r), count = dw_r32(&r);
    if (!r.ok || count > 100000) return nil;
    if (flags & 1) return nil;                        // 带删除标记的包：DR3 无此语义，视为无效
    NSMutableArray *out = [NSMutableArray array];
    for (uint32_t i = 0; i < count && r.ok; i++) {
        uint32_t pl = dw_r32(&r);
        if (!r.ok || pl > 4096) return nil;
        const uint8_t *pb = dw_rbytes(&r, pl);
        if (!r.ok) return nil;
        uint64_t mt = dw_r64(&r), sz = dw_r64(&r);
        const uint8_t *dat = dw_rbytes(&r, (NSUInteger)sz);
        if (!r.ok || sz > 64ull * 1024 * 1024) return nil;
        DWPackEntry *e = [DWPackEntry new];
        e.path = [[NSString alloc] initWithBytes:pb length:pl encoding:NSUTF8StringEncoding];
        e.mtime = mt; e.size = sz;
        e.data = dat ? [NSData dataWithBytes:dat length:(NSUInteger)sz] : [NSData data];
        if (!e.path) return nil;
        [out addObject:e];
    }
    return r.ok ? out : nil;
}

// ---------- 单元扫描（唯一单元 = Documents/save 全树；已提交目录只在 Commit 时变化） ----------
// 点文件不进包；*.tmp / *.seed / *.lang 是宿主 tmp+rename 的瞬态名（hle_season.c 等），同样跳过
static BOOL dw_skip_name(NSString *rel) {
    return [rel hasSuffix:@".tmp"] || [rel hasSuffix:@".seed"] || [rel hasSuffix:@".lang"];
}

@interface DWUnit : NSObject
@property uint64_t mtime;                   // 树内文件 mtime 的最大值（毫秒）
@property uint64_t size;                    // 字节和
@property (strong) NSArray<DWPackEntry *> *entries;
@end
@implementation DWUnit
- (NSString *)desc { return [NSString stringWithFormat:@"save(mtime=%llu,size=%llu,%lu文件)",
                             (unsigned long long)_mtime, (unsigned long long)_size,
                             (unsigned long)_entries.count]; }
@end

static DWUnit *dw_scan_unit(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *at = [fm attributesOfItemAtPath:g_saveDir error:nil];
    if (!at || [at fileType] != NSFileTypeDirectory) return nil;
    NSMutableArray<DWPackEntry *> *es = [NSMutableArray array];
    uint64_t mt = 0, sz = 0;
    for (NSString *s in [fm subpathsAtPath:g_saveDir] ?: @[]) {
        if (![s length] || [s hasPrefix:@"."] || [s containsString:@"/."]) continue;
        if (dw_skip_name(s)) continue;
        NSString *full = [g_saveDir stringByAppendingPathComponent:s];
        NSDictionary *fa = [fm attributesOfItemAtPath:full error:nil];
        if (!fa || [fa fileType] != NSFileTypeRegular) continue;
        NSDate *md = fa[NSFileModificationDate];
        uint64_t m = md ? (uint64_t)(md.timeIntervalSince1970 * 1000) : 0;
        uint64_t n = fa[NSFileSize] ? [fa[NSFileSize] unsignedLongLongValue] : 0;
        DWPackEntry *e = [DWPackEntry new];
        e.path = s; e.mtime = m; e.size = n;
        [es addObject:e];
        if (m > mt) mt = m;
        sz += n;
    }
    if (!es.count) return nil;
    DWUnit *u = [DWUnit new];
    u.entries = es; u.mtime = mt; u.size = sz;
    return u;
}

// ---------- WebDAV 客户端（同步式，只在 worker 线程用） ----------
static NSURLSession *g_sess;
static NSMutableCharacterSet *g_segAllowed;

static NSString *dw_enc_seg(NSString *s) {
    if (!g_segAllowed) {
        g_segAllowed = [[NSCharacterSet URLPathAllowedCharacterSet] mutableCopy];
        [g_segAllowed removeCharactersInString:@"/?#"];
    }
    return [s stringByAddingPercentEncodingWithAllowedCharacters:g_segAllowed] ?: s;
}

@interface DWResp : NSObject
@property NSInteger status;    // -1 = 网络错误/超时
@property (strong) NSData *body;
@property (strong) NSString *err;
@end
@implementation DWResp
@end

static DWResp *dw_http(NSString *method, NSString *url, NSData *body, double timeout) {
    if (!g_sess) {
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        c.waitsForConnectivity = NO;
        g_sess = [NSURLSession sessionWithConfiguration:c];
    }
    NSURL *urlObj = [NSURL URLWithString:url];
    if (!urlObj) {   // 拼出的地址不合法（含空格/中文未转义等）：直接报出来，不发请求
        DWResp *bad = [DWResp new];
        bad.status = -1;
        bad.err = [NSString stringWithFormat:@"URL 不合法：%@", url];
        return bad;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:urlObj];
    req.HTTPMethod = method;
    req.timeoutInterval = MAX(1.0, timeout);
    if (g_authHeader) [req setValue:g_authHeader forHTTPHeaderField:@"Authorization"];
    if (body) {
        req.HTTPBody = body;
        [req setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    }
    DWResp *r = [DWResp new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[g_sess dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { r.status = -1; r.err = err.localizedDescription; }
        else if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            r.status = [(NSHTTPURLResponse *)resp statusCode];
            r.body = data ?: [NSData data];
        } else { r.status = -1; r.err = @"非 HTTP 响应"; }
        dispatch_semaphore_signal(done);
    }] resume];
    if (dispatch_semaphore_wait(done,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout * 2 + 5) * NSEC_PER_SEC)))) {
        r.status = -1; r.err = @"信号量超时";
    }
    return r;
}

static NSString *g_base;   // 主机 + url 路径段 + cfgDir 段（每段已转义），结尾不带 '/'
static NSArray<NSString *> *g_baseSegs;   // url 路径段 + cfgDir 段（未转义，MKCOL 链用）

static void dw_base_init(void) {
    NSString *u = [g_cfgUrl stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([u hasSuffix:@"/"]) u = [u substringToIndex:u.length - 1];
    NSURL *parsed = [NSURL URLWithString:u];
    NSMutableArray *segs = [NSMutableArray array];
    for (NSString *s in parsed.pathComponents ?: @[])
        if (s.length && ![s isEqualToString:@"/"]) [segs addObject:s];
    for (NSString *s in [g_cfgDir componentsSeparatedByString:@"/"])
        if (s.length) [segs addObject:s];
    g_baseSegs = segs;
    NSString *host = [NSString stringWithFormat:@"%@://%@%@", parsed.scheme, parsed.host,
                      parsed.port ? [NSString stringWithFormat:@":%@", parsed.port] : @""];
    NSMutableArray *enc = [NSMutableArray array];
    for (NSString *s in segs) [enc addObject:dw_enc_seg(s)];
    g_base = enc.count
        ? [host stringByAppendingFormat:@"/%@", [enc componentsJoinedByString:@"/"]]
        : host;
}

static NSString *dw_url(NSString *lastSegEncoded) {
    return [g_base stringByAppendingFormat:@"/%@", lastSegEncoded];
}
static NSString *dw_pack_url(void) { return dw_url(@"packs/save.pack"); }
static NSString *dw_manifest_url(void) { return dw_url(@"manifest.json"); }

// MKCOL 父先子后（d2r-webdav 真机教训）；已存在（405/200）算成功
static BOOL dw_mkcol_chain(NSArray<NSString *> *extraSegs) {
    NSURL *parsed = [NSURL URLWithString:g_base];
    NSString *host = [NSString stringWithFormat:@"%@://%@%@", parsed.scheme, parsed.host,
                      parsed.port ? [NSString stringWithFormat:@":%@", parsed.port] : @""];
    NSMutableArray *segs = [NSMutableArray arrayWithArray:g_baseSegs];
    [segs addObjectsFromArray:extraSegs];
    for (NSUInteger i = 0; i < segs.count; i++) {
        NSMutableString *url = [NSMutableString stringWithString:host];
        for (NSUInteger j = 0; j <= i; j++)   // 逐级拼前缀：seg0、seg0/seg1、…
            [url appendFormat:@"/%@", dw_enc_seg(segs[j])];
        DWResp *r = dw_http(@"MKCOL", url, nil, 10.0);
        if (r.status != 201 && r.status != 200 && r.status != 405 && r.status != 301) {
            dw_log(@"MKCOL %@ -> %ld（忽略，PUT 失败时会再试）", url, (long)r.status);
        }
    }
    return YES;
}

// PUT，带 409/404 补建父目录重试、503/429 限速退避
static NSInteger dw_put(NSString *url, NSData *body, NSString *mkcolSeg) {
    static const double backoff[] = { 10.0, 30.0, 90.0 };
    NSInteger st = -1;
    for (int attempt = 0; attempt < 5; attempt++) {
        DWResp *r = dw_http(@"PUT", url, body, 120.0);
        st = r.status;
        if (st == 201 || st == 200 || st == 204) return st;
        if ((st == 409 || st == 404) && mkcolSeg) {
            dw_log(@"PUT %ld，补建目录重试", (long)st);
            dw_mkcol_chain(@[mkcolSeg]);
            mkcolSeg = nil;
            continue;
        }
        if (st == 503 || st == 429) {
            double w = backoff[MIN(attempt, 2)];
            dw_log(@"限速 %ld，等 %.0f 秒重试", (long)st, w);
            [NSThread sleepForTimeInterval:w];
            continue;
        }
        dw_log(@"PUT 失败 %ld：%@", (long)st, r.err ?: @"");
        return st;
    }
    return st;
}

// ---------- 云端 manifest ----------
static NSMutableDictionary *g_remote;   // {"format","device","updated","units":{save:{mtime,size,deleted}}}

static NSMutableDictionary *dw_manifest_fetch(double timeout) {
    DWResp *r = dw_http(@"GET", dw_manifest_url(), nil, timeout);
    if (r.status == 404) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        m[@"format"] = @1; m[@"units"] = [NSMutableDictionary dictionary];
        return m;
    }
    if (r.status != 200 || !r.body) {
        dw_log(@"取 manifest 失败 %ld：%@", (long)r.status, r.err ?: @"");
        return nil;
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:r.body options:0 error:&err];
    id unitsObj = [obj isKindOfClass:[NSDictionary class]] ? obj[@"units"] : nil;
    if (err || ![obj isKindOfClass:[NSDictionary class]]
        || ![unitsObj isKindOfClass:[NSDictionary class]]) {
        dw_log(@"manifest 不是合法 JSON");
        return nil;
    }
    NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:obj];
    m[@"units"] = [NSMutableDictionary dictionaryWithDictionary:(obj[@"units"] ?: @{})];
    return m;
}

static BOOL dw_manifest_store(void) {
    g_remote[@"format"] = @1;
    g_remote[@"device"] = g_deviceId;
    g_remote[@"updated"] = @(dw_now_ms());
    NSData *d = [NSJSONSerialization dataWithJSONObject:g_remote options:0 error:nil];
    if (!d) return NO;
    NSInteger st = dw_put(dw_manifest_url(), d, nil);
    return st == 200 || st == 201 || st == 204;
}

// 单元视图 {mtime,size,deleted}
static NSDictionary *dw_view(uint64_t mtime, uint64_t size) {
    return @{ @"mtime": @(mtime), @"size": @(size), @"deleted": @NO };
}
static uint64_t dw_view_mtime(NSDictionary *v) {
    return v && [v[@"mtime"] respondsToSelector:@selector(longLongValue)]
        ? [v[@"mtime"] unsignedLongLongValue] : 0;
}
static uint64_t dw_view_size(NSDictionary *v) {
    return v && [v[@"size"] respondsToSelector:@selector(longLongValue)]
        ? [v[@"size"] unsignedLongLongValue] : 0;
}

// ---------- 本地状态（上次同步成功后的视图；存 Library，不进存档目录） ----------
static NSMutableDictionary *g_state;

static void dw_state_load(void) {
    g_state = [NSMutableDictionary dictionary];
    g_state[@"v"] = @1;
    g_state[@"units"] = [NSMutableDictionary dictionary];
    NSData *d = [NSData dataWithContentsOfFile:g_stateFile];
    if (!d) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]
        || ![obj[@"units"] isKindOfClass:[NSDictionary class]]) return;
    g_state = [NSMutableDictionary dictionaryWithDictionary:obj];
    g_state[@"units"] = [NSMutableDictionary dictionaryWithDictionary:obj[@"units"]];
}

static void dw_state_save(void) {
    g_state[@"updated"] = @(dw_now_ms());
    NSData *d = [NSJSONSerialization dataWithJSONObject:g_state options:0 error:nil];
    if (!d) return;
    NSString *tmp = [g_stateFile stringByAppendingString:@".tmp"];
    if ([d writeToFile:tmp atomically:YES])
        [[NSFileManager defaultManager] removeItemAtPath:g_stateFile error:nil]
        , [[NSFileManager defaultManager] moveItemAtPath:tmp toPath:g_stateFile error:nil];
}

static NSDictionary *dw_state_unit(void) {
    id u = g_state[@"units"][DW_UNIT];
    return [u isKindOfClass:[NSDictionary class]] ? u : nil;
}

// ---------- 备份（被换下的整档挪进去，留 3 份） ----------
static void dw_backup_trim(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *prefix = [NSString stringWithFormat:@"%@-", DW_UNIT];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *n in [fm contentsOfDirectoryAtPath:g_backupDir error:nil] ?: @[])
        if ([n hasPrefix:prefix]) [names addObject:n];
    if (names.count <= 3) return;
    [names sortUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i + 3 < names.count; i++)
        [fm removeItemAtPath:[g_backupDir stringByAppendingPathComponent:names[i]] error:nil];
}

static NSString *dw_backup_slot(uint64_t stamp) {
    NSString *dir = [g_backupDir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@-%llu", DW_UNIT, (unsigned long long)stamp]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    dw_backup_trim();
    return dir;
}

// ---------- 单元安装（只在启动窗口内、dm_main 放行之前做） ----------
static void dw_set_mtime(NSString *path, uint64_t ms) {
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:ms / 1000.0];
    [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: d}
                                     ofItemAtPath:path error:nil];
}

// 先把包内容写进同级暂存目录 save.webdav，再与已提交目录原子互换（renamex_np RENAME_SWAP，
// 与 hle_fs.c 的存档提交同款），最后把换下来的旧档挪进备份——任何瞬间 save 都要么是旧版要么是新版，
// 绝无半写状态。暂存目录名与 hle_fs 的 save.work / save.new 不冲突。
static BOOL dw_install_unit(NSArray<DWPackEntry *> *entries) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *stage = [g_saveDir stringByAppendingString:@".webdav"];
    if ([fm fileExistsAtPath:stage] && ![fm removeItemAtPath:stage error:nil]) {
        dw_log(@"【红】安装：清不掉残留暂存目录 %@", stage);
        return NO;
    }
    if (![fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil]) {
        dw_log(@"【红】安装：建暂存目录失败");
        return NO;
    }
    for (DWPackEntry *e in entries) {
        NSString *p = [stage stringByAppendingPathComponent:e.path];
        NSString *parent = [p stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![e.data writeToFile:p atomically:YES]) {
            dw_log(@"【红】安装：写 %@ 失败", p);
            [fm removeItemAtPath:stage error:nil];
            return NO;
        }
        dw_set_mtime(p, e.mtime);
    }
    if (![fm fileExistsAtPath:g_saveDir]) {
        // 本机还没有存档目录（全新装机）：暂存目录改名就位即可
        if ([fm moveItemAtPath:stage toPath:g_saveDir error:nil]) return YES;
        dw_log(@"【红】安装：就位失败（%@ → %@）", stage, g_saveDir);
        [fm removeItemAtPath:stage error:nil];
        return NO;
    }
    if (renamex_np(stage.fileSystemRepresentation, g_saveDir.fileSystemRepresentation, RENAME_SWAP)) {
        dw_log(@"【红】安装：原子互换失败（errno=%d），已提交版本不变", errno);
        [fm removeItemAtPath:stage error:nil];
        return NO;
    }
    // 换下来的旧版（此刻在暂存名下）整份进备份；挪不动就删（云端还有，本地也有刚装好的新版）
    NSDictionary *at = [fm attributesOfItemAtPath:stage error:nil];
    NSDate *md = at[NSFileModificationDate];
    NSString *slot = dw_backup_slot(md ? (uint64_t)(md.timeIntervalSince1970 * 1000) : dw_now_ms());
    if (![fm moveItemAtPath:stage toPath:[slot stringByAppendingPathComponent:DW_UNIT] error:nil])
        [fm removeItemAtPath:stage error:nil];
    return YES;
}

// ---------- 启动下拉（startMode 起线程；wait_boot 放行 dm_main 前关窗） ----------
static atomic_int g_applyAllowed;          // 1 = 启动窗口内（允许安装进本地）
static atomic_int g_bootDoneFlag;          // 1 = 下拉阶段结束（信号量之外的双保险）
static dispatch_semaphore_t g_bootDone;
static uint64_t g_bootDeadline;            // 毫秒；boot_start 时定死

static void dw_boot_pull(void) {
    uint64_t t0 = dw_now_ms();
    NSMutableDictionary *remote = dw_manifest_fetch(MAX(1.0, g_cfgBootTimeout - 0.5));
    if (!remote) { dw_log(@"启动下拉：取不到 manifest，本次不拉（本地档稍后照常推送）"); return; }
    g_remote = remote;
    DWUnit *local = dw_scan_unit();
    NSDictionary *rv = remote[@"units"][DW_UNIT];
    uint64_t rM = dw_view_mtime(rv), lM = local ? local.mtime : 0;
    if (!rv || rM <= lM) {
        // 本地新或平（或云端无记录）：不拉。state 保持上次同步视图不动——
        // 上次没传完的档（state 落后于本地）正是靠这个差距被随后的「启动补推」认出来
        // （d2r-webdav v1 在这里把 state 直接写成当前本地视图，会抹掉待推送标记）
        dw_log(@"启动下拉完成：云端 %@，本地 %@（%.1f 秒）",
               rv ? @"不比本地新" : @"无记录", local ? local.desc : @"无档",
               (dw_now_ms() - t0) / 1000.0);
        return;
    }
    if (dw_now_ms() > g_bootDeadline) {
        dw_log(@"启动下拉超时，本次不拉（下次启动再对齐）");
        return;
    }
    double remain = (double)(g_bootDeadline - dw_now_ms()) / 1000.0;
    DWResp *r = dw_http(@"GET", dw_pack_url(), nil, MAX(1.0, MIN(30.0, remain)));
    if (r.status != 200 || !r.body) {
        dw_log(@"下拉取包失败 %ld，下次启动再试（本地档保留）", (long)r.status);
        return;
    }
    NSArray *entries = dw_pack_parse(r.body);
    if (!entries) { dw_log(@"下拉包格式不对，跳过（本地档保留）"); return; }
    if (!atomic_load(&g_applyAllowed)) {
        dw_log(@"【红】已过启动窗口，不安装（本地版本保留，本机若更新稍后按新者推送）");
        return;
    }
    if (dw_install_unit(entries)) {
        g_state[@"units"][DW_UNIT] = dw_view(rM, dw_view_size(rv));
        dw_log(@"下拉：save ← 云端（%lu 文件，%.1f KB；本地若有旧份已进备份）",
               (unsigned long)entries.count, r.body.length / 1024.0);
    } else {
        dw_log(@"【红】安装失败，下次启动再试（本地档保留）");
    }
}

// ---------- 推送（worker 线程；只读本地、只写云端） ----------
static uint64_t g_skipLatchM;              // 防倒退守卫触发时的本地视图（同视图不再重复尝试/刷日志）
static uint64_t g_skipLatchS;

static void dw_push(NSString *why) {
    DWUnit *local = dw_scan_unit();
    if (!local) return;                                 // 本机无档：没什么可推
    NSDictionary *st = dw_state_unit();
    if (st && dw_view_mtime(st) == local.mtime && dw_view_size(st) == local.size)
        return;                                         // 与上次同步视图一致：干净
    if (local.mtime == g_skipLatchM && local.size == g_skipLatchS)
        return;                                         // 守卫刚拦过且本地没再变：静默跳过
    // 每次推送前重取云端 manifest（很小的一个 GET），既做防倒退比较也是写入基础
    NSMutableDictionary *remote = dw_manifest_fetch(10.0);
    if (!remote) { dw_log(@"推送中止（%@）：取不到 manifest", why); return; }
    g_remote = remote;
    NSDictionary *rv = remote[@"units"][DW_UNIT];
    uint64_t rM = dw_view_mtime(rv);
    if (rv && rM > (st ? dw_view_mtime(st) : 0) && rM > local.mtime) {
        // 防倒退守卫：云端比本机上次同步视图新、也比本机当前档新（别的设备推过更进的进度）
        // → 不推，留给下次启动下拉对齐；本地继续存档不受影响，等本地真的更新过云端再推
        g_skipLatchM = local.mtime; g_skipLatchS = local.size;
        dw_log(@"推送跳过（%@）：云端更新（%llu > 本地 %llu），下次启动下拉对齐",
               why, (unsigned long long)rM, (unsigned long long)local.mtime);
        return;
    }
    dw_log(@"推送（%@）：%@", why, local.desc);
    NSMutableArray<DWPackEntry *> *es = [NSMutableArray array];
    uint64_t mt = 0, sz = 0;
    for (DWPackEntry *e in local.entries) {
        NSData *d = [NSData dataWithContentsOfFile:[g_saveDir stringByAppendingPathComponent:e.path]];
        if (!d) { dw_log(@"读文件失败（可能在存档换盘中），下轮再推：%@", e.path); return; }
        DWPackEntry *ne = [DWPackEntry new];
        ne.path = e.path; ne.mtime = e.mtime; ne.size = d.length; ne.data = d;
        [es addObject:ne];
        if (ne.mtime > mt) mt = ne.mtime;
        sz += d.length;
    }
    if (sz > 64ull * 1024 * 1024) { dw_log(@"存档超过 64MB，不推"); return; }
    NSData *pack = dw_pack_build(es);
    NSInteger st2 = dw_put(dw_pack_url(), pack, @"packs");
    if (st2 == 200 || st2 == 201 || st2 == 204) {
        g_remote[@"units"][DW_UNIT] = dw_view(mt, sz);
        if (dw_manifest_store()) {
            g_state[@"units"][DW_UNIT] = dw_view(mt, sz);
            dw_state_save();
            g_skipLatchM = 0; g_skipLatchS = 0;
            dw_log(@"推送：save → 云端（%.1f KB）", pack.length / 1024.0);
        } else {
            dw_log(@"【红】manifest 写回失败（包已传上），下轮重试");
        }
    } else {
        dw_log(@"【红】推送失败（%ld），下轮再试", (long)st2);
    }
}

// ---------- 自检 ----------
static void dw_selftest(void) {
    NSMutableArray *es = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        DWPackEntry *e = [DWPackEntry new];
        e.path = [NSString stringWithFormat:@"dir%d/文件%d.bin", i, i];
        e.mtime = 1770000000123ull + i;
        e.size = 4 + i;
        e.data = [NSData dataWithBytes:"abcd" length:4 + i];
        [es addObject:e];
    }
    NSData *pack = dw_pack_build(es);
    NSArray *back = dw_pack_parse(pack);
    BOOL pass = back.count == 3;
    for (NSUInteger i = 0; pass && i < 3; i++) {
        DWPackEntry *a = es[i], *b = back[i];
        pass = [a.path isEqualToString:b.path] && a.mtime == b.mtime
               && a.size == b.size && [a.data isEqualToData:b.data];
    }
    pass = pass && dw_pack_parse([@"xx" dataUsingEncoding:NSUTF8StringEncoding]) == nil;
    dw_log(@"自检：pack 往返 %@", pass ? @"通过" : @"【红】未通过");
}

// ---------- worker 线程（下拉阶段 + 常驻推送循环） ----------
static dispatch_semaphore_t g_wake;        // commit hook / 切后台即时唤醒（超时 = 轮询周期）
static atomic_int g_pushNow;
static char g_pushWhy[48];

static void dw_thread_main(void) {
    @autoreleasepool {
        @try {
            dw_base_init();   // 拼出「主机 + url 路径 + dir」的基址，第一次网络访问前必须做
            dw_log(@"dr3-webdav %@ 启动：基址 %@ 设备 %@", DW_VER, g_base, g_deviceId);
            dw_state_load();
            dw_boot_pull();
            atomic_store(&g_bootDoneFlag, 1);
            dispatch_semaphore_signal(g_bootDone);
            // 补推：上次退出前没来得及传的
            dw_push(@"启动补推");
            [[NSNotificationCenter defaultCenter] addObserverForName:
                [NSString stringWithUTF8String:"UIApplicationDidEnterBackgroundNotification"]
                object:nil queue:nil usingBlock:^(NSNotification *n) {
                    (void)n; dm_webdav_push_now("切后台");
                }];
            uint64_t pendingSince = 0;
            while (YES) {
                dispatch_semaphore_wait(g_wake,
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(g_cfgPoll * NSEC_PER_SEC)));
                if (atomic_exchange(&g_pushNow, 0)) {
                    dw_push([NSString stringWithUTF8String:g_pushWhy]);
                    pendingSince = 0;
                    continue;
                }
                @autoreleasepool {
                    DWUnit *local = dw_scan_unit();
                    NSDictionary *st = dw_state_unit();
                    BOOL dirty = local && (!st || dw_view_mtime(st) != local.mtime
                                           || dw_view_size(st) != local.size);
                    uint64_t now = dw_now_ms();
                    if (dirty) {
                        if (!pendingSince) pendingSince = now;
                        // 防抖：最后一次变化后安静 3 秒才推；最长憋 60 秒必推一次
                        if (now - pendingSince > (uint64_t)(g_cfgDebounce * 1000)
                            || now - pendingSince > 60000) {
                            dw_push(@"变更");
                            pendingSince = 0;
                        }
                    } else {
                        pendingSince = 0;
                    }
                }
            }
        } @catch (NSException *e) {
            dw_log(@"【红】worker 异常：%@ %@", e.name, e.reason);
            if (!atomic_exchange(&g_bootDoneFlag, 1)) dispatch_semaphore_signal(g_bootDone);
        }
    }
}

// NSThread 载体（照搬 d2rwebdav 的做法：那套本地 SDK 的 pthread.h 是坏的转发文件，纯 Foundation 最稳）
@interface DWThread : NSObject
- (void)run;
@end
@implementation DWThread
- (void)run { dw_thread_main(); }
@end

// hle_fs.c 存档提交成功时回调（持锁！只做原子标志 + 信号量唤醒，绝不做 IO / 加锁 / 慢调用）
static void dw_commit_hook(const char *commit_dir) {
    (void)commit_dir;
    dm_webdav_push_now("存档提交");
}

void dm_webdav_push_now(const char *why) {
    if (!g_wake) return;   // 未启用：零动作
    snprintf(g_pushWhy, sizeof g_pushWhy, "%s", why ?: "手动");
    atomic_store(&g_pushNow, 1);
    dispatch_semaphore_signal(g_wake);
}

// ---------- 启动入口（main.m startMode 调；用户点「开始」时） ----------
static atomic_int g_active;

static void dw_paths_init(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    g_docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    g_saveDir = [g_docDir stringByAppendingPathComponent:@"save"];
    NSString *appSup = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0];
    g_stateDir = [appSup stringByAppendingPathComponent:@"DR3WebDAV"];
    g_backupDir = [g_stateDir stringByAppendingPathComponent:@"backup"];
    g_tmpDir = [g_stateDir stringByAppendingPathComponent:@"tmp"];
    g_stateFile = [g_stateDir stringByAppendingPathComponent:@"state.json"];
    g_logPath = [g_docDir stringByAppendingPathComponent:@"webdav.log"];
    for (NSString *d in @[g_stateDir, g_backupDir, g_tmpDir])
        [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *idp = [g_stateDir stringByAppendingPathComponent:@"deviceid"];
    NSString *idv = [NSString stringWithContentsOfFile:idp encoding:NSUTF8StringEncoding error:nil];
    if (!idv.length) {
        idv = [[NSUUID UUID] UUIDString];
        [idv writeToFile:idp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    g_deviceId = idv;
}

void dm_webdav_boot_start(void) {
    static int once; if (once++) return;
    @autoreleasepool {
        NSDictionary *cfg = dw_load_config();
        if (!cfg) { dw_log(@"无 Documents/webdav.json，云存档同步停用（把配置放进去重启 App 即可启用）"); return; }
        dw_paths_init();   // 日志路径就位，之后才有完整日志
        if ([cfg[@"selftest"] boolValue]) { dw_selftest(); return; }
        if (!dw_config_apply(cfg) || !g_cfgEnabled) {
            dw_log(@"配置未启用（enabled=false 或 url 缺失），同步停用");
            return;
        }
        atomic_store(&g_active, 1);
        atomic_store(&g_applyAllowed, 1);
        g_bootDeadline = dw_now_ms() + (uint64_t)(g_cfgBootTimeout * 1000);
        g_bootDone = dispatch_semaphore_create(0);
        g_wake = dispatch_semaphore_create(0);
        g_dm_save_commit_hook = dw_commit_hook;   // 游戏每次存档提交 → 立即推送
        @try {
            [NSThread detachNewThreadSelector:@selector(run) toTarget:[DWThread new] withObject:nil];
        } @catch (id e) {   // 线程都起不来：当未启用处理，别把游戏堵在 wait_boot
            dw_log(@"【红】起线程失败，同步停用");
            atomic_store(&g_active, 0);
            g_dm_save_commit_hook = NULL;
        }
    }
}

// ---------- 放行点（main.m front_ios_boot 调；spawn dm_main 之前） ----------
void dm_webdav_wait_boot(void) {
    if (!atomic_load(&g_active)) return;
    // 等下拉做完；至多等到「死线 + 1 秒」（安装本身是本地写，几 MB 也就几十毫秒）
    dispatch_semaphore_wait(g_bootDone, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)((g_cfgBootTimeout + 1.0) * NSEC_PER_SEC)));
    atomic_store(&g_applyAllowed, 0);   // 关窗：此后本次运行绝不再写本地存档
    dw_log(@"启动窗口关闭（下拉%s）", atomic_load(&g_bootDoneFlag) ? "已完成" : "超时弃权");
}
