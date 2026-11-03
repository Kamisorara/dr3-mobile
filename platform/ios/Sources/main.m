// iOS App entry: set the environment (game files, saves, shader libraries), write the host log to Documents/log.txt, create the window (front_ios.m), then run the host's dm_main on a big-stack thread.
// The game files (RomFS) ship inside the App at <App>/romfs; Documents/romfs placed through the Files app is also accepted (lets you swap them without reinstalling).
#import <UIKit/UIKit.h>
#import "LauncherViewController.h"
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include "game_profile.h"   // game profile constants (the RomFS marker path)

int dm_main(int argc, char **argv);   // dm/host/main.c compiled in with -Dmain=dm_main
void dm_host_preload_start(int argc, char **argv);
UIViewController *front_ios_root(void);
void front_ios_focus_event(int ev);
void front_ios_configure_display(int wide, int metalfx, int fill);
void front_ios_configure_aspect(int on);
int dr3_lan_supported(void) __attribute__((weak_import));

static char *g_argv[4]; static int g_argc;
static int g_launch_selected;

static NSDictionary *graphics_profile(void) {
    NSString *path=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm/mobile-graphics.json"];
    NSData *data=[NSData dataWithContentsOfFile:path];
    id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    return [value isKindOfClass:NSDictionary.class]?value:@{};
}
// 适配模式可用性：pack 产物带 D3 参数槽（main.params.tsv 有数据行）→ 宿主能按屏幕比例给渲染分辨率。
// | Aspect mode availability: the pack carries the D3 parameter slots (main.params.tsv has data rows),
// | so the host can feed the render resolution from the screen ratio.
static BOOL aspect_available(void) {
    NSDictionary *profile=graphics_profile();
    return [profile[@"runtime_aspect"] boolValue];
}

#include "../../../native/asset_inventory.h"

// 资源根定位（含容错，逐个试）：
//   Documents/<sub>             标准位置（资源文件夹整个拷进来）
//   Documents                   资源的内容直接放进 Documents（没有 <sub> 这一层）
//   bundle/<sub>                包内（--embed-assets 构建才有）
//   Documents/<sub>/<一级子目录>   把整个解包目录拖了进来（如 Documents/解包资源/RomFS/…）：唯一的匹配者自动下钻；
//                               多个匹配者不算数（不猜），由调用方的诊断把目录内容亮出来让用户自己挪。
// marker = 这类资源目录必须含的文件（RomFS：CPKs/CoreCommon.cpk；中文 DLC：11/ztCN_CoreCommon.cpk）。
static NSString *resource_locate(NSFileManager *fm, NSString *doc, NSString *res, NSString *sub, NSString *marker, BOOL *buried) {
    *buried = NO;
    for (NSString *base in @[[doc stringByAppendingPathComponent:sub], doc, [res stringByAppendingPathComponent:sub]])
        if ([fm fileExistsAtPath:[base stringByAppendingPathComponent:marker]]) return base;
    NSString *primary = [doc stringByAppendingPathComponent:sub];
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:primary error:nil]) {
        if (asset_junk(entry)) continue;   // Finder / Windows 的杂物不算层级
        NSString *candidate = [primary stringByAppendingPathComponent:entry];
        if ([fm fileExistsAtPath:[candidate stringByAppendingPathComponent:marker]]) [found addObject:candidate];
    }
    if (found.count == 1) { *buried = YES; return found[0]; }
    return nil;
}

static void dump_dir(NSFileManager *fm, NSString *dir, const char *label) {
    if (![fm fileExistsAtPath:dir]) { fprintf(stderr, "boot: %s 不存在 | %s does not exist\n", label, label); return; }
    NSArray *entries = asset_top_entries(fm, dir, 8);
    fprintf(stderr, "boot: %s 顶层（%lu 项）| %s top level (%lu entries):", label, (unsigned long)entries.count, label, (unsigned long)entries.count);
    for (NSString *e in entries) fprintf(stderr, " %s", e.UTF8String);
    fprintf(stderr, "\n");
}

static NSString *romfs_locate(NSFileManager *fm, NSString *doc) {
    BOOL buried = NO;
    NSString *romfs = resource_locate(fm, doc, NSBundle.mainBundle.resourcePath, @"romfs", @DM_GAME_ROMFS_MARKER, &buried);
    if (!romfs) {   // 都没中：把 Documents 与 Documents/romfs 的顶层亮出来，用户对照着挪
        fprintf(stderr, "boot: 没找到游戏文件——需要能沿着 %s 找到（以下任一位置）| the game files were not found; %s must resolve in one of:\n", DM_GAME_ROMFS_MARKER, DM_GAME_ROMFS_MARKER);
        fprintf(stderr, "boot:   Documents/romfs/… · Documents/…（资源内容直接放 Documents）· Documents/romfs/<某目录>/…（整个解包目录拖进来）\n");
        dump_dir(fm, doc, "Documents");
        dump_dir(fm, [doc stringByAppendingPathComponent:@"romfs"], "Documents/romfs");
        return nil;
    }
    if (buried) fprintf(stderr, "boot: 游戏文件在 Documents/romfs 的一级子目录里（已自动定位）| game files sit one level inside Documents/romfs (located automatically)\n");
    return romfs;
}

// Boot prerequisites (done before UIApplicationMain): directories / environment variables / log -- the host's early load reads these
static int boot_env(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *res = NSBundle.mainBundle.resourcePath;
    for (NSString *d in @[@"save", @"temp"]) [fm createDirectoryAtPath:[doc stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
    // Log: the host only writes to stderr; redirect it to Documents/log.txt (the previous one is kept as log.prev.txt), retrieve it from the Files app when something goes wrong
    NSString *log = [doc stringByAppendingPathComponent:@"log.txt"], *prev = [doc stringByAppendingPathComponent:@"log.prev.txt"];
    [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    // Environment switch files (for on-device diagnostics: a sideloaded app cannot be given environment variables from outside): one KEY=VALUE per line, # starts a comment; Documents/env.txt takes precedence over dm/env.txt in the bundle (put there by build_ipa.sh's DM_ENV_FILE)
    for (NSString *ef in @[[doc stringByAppendingPathComponent:@"env.txt"], [[res stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"env.txt"]]) {
        NSString *txt = [NSString stringWithContentsOfFile:ef encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
            if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
            NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
            if (!getenv(k.UTF8String)) { setenv(k.UTF8String, v.UTF8String, 0); fprintf(stderr, "boot: 环境 %s=%s（%s）\n", k.UTF8String, v.UTF8String, ef.lastPathComponent.UTF8String); }
        }
    }
    // Metal HUD 的持久偏好提前生效（此时进程里还没碰过 Metal）：Apple 的 libMTLHud 看到
    // MTL_HUD_ENABLED「存在」就可能挂上（值是 0 也不行），所以关 = unsetenv、开 = setenv 1。
    // env.txt 若带了旧默认 1，这里随即撤掉——出厂默认必须是"变量不存在"。
    // | Apply the persisted Metal-HUD preference before anything touches Metal: Apple's libMTLHud
    // | activates on the variable's PRESENCE (a value of 0 does not disable it), so off = unsetenv
    // | and on = setenv 1. An env.txt carrying the old default of 1 is revoked right here.
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"LaunchMetalHUD"]) unsetenv("MTL_HUD_ENABLED");
    // Documents/env.txt 不存在时生成一份带注释的模板：文件 App 里可见可编辑（iOS 没法新建纯文本），
    // 常用开关已列进注释；改完重启游戏生效（boot_env 只在启动时读）。
    // | Create a commented env.txt template in Documents when absent: visible and editable in the
    // | Files app (iOS cannot create plain text files); common switches are listed in comments.
    NSString *envf = [doc stringByAppendingPathComponent:@"env.txt"];
    if (![fm fileExistsAtPath:envf]) {
        NSString *tpl = [NSString stringWithFormat:
            @"# DR3Mobile 环境开关：每行 KEY=VALUE，# 开头是注释；改完重启游戏生效。\n"
             "# 常用开关已做进启动器界面（Metal HUD、触摸日志、MetalFX、局域网），一般不用改这里。\n"
             "\n"
             "# 触屏诊断：游戏每次读取触摸点记一行（进 Documents/log.txt）\n"
             "#DM_TOUCH_LOG=1\n"];
        [[tpl dataUsingEncoding:NSUTF8StringEncoding] writeToFile:envf atomically:YES];
    }
    NSString *romfs = romfs_locate(fm, doc);
    if (!romfs) return 0;
    BOOL aocBuried = NO;
    NSString *aoc = resource_locate(fm, doc, res, @"aoc", @"11/ztCN_CoreCommon.cpk", &aocBuried);
    if (!aoc) {   // 中文 DLC 没定位到：同样把候选位置亮出来（缺失只影响中文语音/文本，但校验不过不启动）
        fprintf(stderr, "boot: 没找到中文 DLC——需要 11/ztCN_CoreCommon.cpk 能在以下位置之一解析 | the Chinese DLC was not found; 11/ztCN_CoreCommon.cpk must resolve in one of:\n");
        fprintf(stderr, "boot:   Documents/aoc/… · Documents/…（内容直接放）· Documents/aoc/<某目录>/…（整个 DLC 目录拖进来）\n");
        dump_dir(fm, doc, "Documents");
        dump_dir(fm, [doc stringByAppendingPathComponent:@"aoc"], "Documents/aoc");
        return 0;
    }
    if (aocBuried) fprintf(stderr, "boot: 中文 DLC 在 Documents/aoc 的一级子目录里（已自动定位）| the Chinese DLC sits one level inside Documents/aoc (located automatically)\n");
    NSData *manifestData = [NSData dataWithContentsOfFile:[res stringByAppendingPathComponent:@"dm/private-assets.json"]];
    NSDictionary *inventory = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
    if (![inventory isKindOfClass:NSDictionary.class] || !assets_ready(romfs,inventory[@"romfs"],@"RomFS") || !assets_ready(aoc,inventory[@"aoc"],@"Chinese DLC")) return 0;
    fprintf(stderr, "boot: 游戏文件 %s\n", romfs.fileSystemRepresentation);
    setenv("DM_ROMFS", romfs.fileSystemRepresentation, 0);
    setenv("DM_SAVE", [doc stringByAppendingPathComponent:@"save"].fileSystemRepresentation, 0);
    setenv("DM_TEMP", [doc stringByAppendingPathComponent:@"temp"].fileSystemRepresentation, 0);
    NSString *dm = [res stringByAppendingPathComponent:@"dm"];
    setenv("DM_NVN_SHMAP", [dm stringByAppendingPathComponent:@"shader_map.tsv"].fileSystemRepresentation, 0);
    setenv("DM_MSL_DIR", [res stringByAppendingPathComponent:@"msl"].fileSystemRepresentation, 0);
    setenv("DM_FONT_DIR", [dm stringByAppendingPathComponent:@"font"].fileSystemRepresentation, 0);   // Shared-font stand-ins (standard.ttf / nintendo_ext.ttf): iOS lacks the macOS font path
    if ([fm fileExistsAtPath:aoc]) setenv("DM_AOC_DIR", aoc.fileSystemRepresentation, 0);
    chdir(doc.fileSystemRepresentation);
    g_argv[0] = strdup("dmhost"); g_argv[1] = strdup(dm.fileSystemRepresentation); g_argc = 2;
    // The launcher commits display settings before loading signed guest images.
    return 1;
}
static int g_boot_ok;

static void *boot_thread(void *p) {
    (void)p;
    static char alt[65536]; stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);   // crash printing must work on the host thread too
    int rc = dm_main(g_argc, g_argv);
    fprintf(stderr, "boot: dm_main 返回 %d\n", rc);
    return NULL;
}
void front_ios_boot(void) {   // Called by front_ios.m once the window and Metal view exist
    static int once; if (!g_launch_selected || !g_boot_ok || once++) return;
    void front_ios_audio_session(void); front_ios_audio_session();   // set a short I/O buffer before the game opens audio output (front_ios.m)
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);   // the Switch main thread stack is set by npdm; the host gives plenty
    pthread_t t; pthread_create(&t, &a, boot_thread, NULL); pthread_detach(t);
}
int front_ios_boot_ok(void) { return g_boot_ok; }

@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
}
@end

// Scene lifecycle: create the window + hand focus events to front_ios.m
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)startMode:(NSInteger)mode hud:(BOOL)hud metalfx:(BOOL)metalfx lan:(BOOL)lan touchLog:(BOOL)touchLog {
    if(g_launch_selected || !g_boot_ok)return;
    BOOL aspect = mode==2;
    if(aspect&&!aspect_available())return;
    BOOL fill = mode==1;
    if(hud)setenv("MTL_HUD_ENABLED","1",1);else unsetenv("MTL_HUD_ENABLED");   // 存在即激活，0 不算关 | presence activates it; 0 is not off
    if(touchLog)setenv("DM_TOUCH_LOG","1",1);else unsetenv("DM_TOUCH_LOG");    // 同上（hle_touch 见变量即开） | same rule in hle_touch
    setenv("DM_METALFX",metalfx?"spatial":"off",1);
    setenv("DM_IOS_GRAPHICS_MODE","normal",1);   // 适配不换映像：参数槽在宿主，映像同一张 | aspect keeps the same image: the slots live in the host
    setenv("DM_GAME_RES","1280x720",1);
    setenv("DM_DR3_LAN",lan?"1":"0",1);
    fprintf(stderr,"boot: launch mode=%s HUD=%d MetalFX=%s LAN=%d\n",aspect?"aspect":fill?"fill":"normal",hud,metalfx?"spatial":"off",lan);
    front_ios_configure_display(0,metalfx,fill);
    front_ios_configure_aspect(aspect);
    dm_host_preload_start(g_argc,g_argv);
    g_launch_selected=1;
    self.window.rootViewController=front_ios_root();
    dispatch_async(dispatch_get_main_queue(),^{if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive)front_ios_focus_event(3);});
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    BOOL lan=dr3_lan_supported&&dr3_lan_supported();
    LauncherViewController *launcher=[[LauncherViewController alloc] initWithWideAvailable:aspect_available() lanAvailable:lan ready:g_boot_ok reason:@"游戏和中文资源未准备完整，请完成传输后重新打开。"];
    __weak SceneDelegate *weakSelf=self;
    launcher.onPlay=^(NSInteger mode,BOOL hud,BOOL metalfx,BOOL lan,BOOL touchLog){[weakSelf startMode:mode hud:hud metalfx:metalfx lan:lan touchLog:touchLog];};
    self.window.rootViewController=launcher;
    [self.window makeKeyAndVisible];
    UIApplication.sharedApplication.idleTimerDisabled=YES;
}
- (void)sceneWillResignActive:(UIScene *)s { front_ios_focus_event(0); }
- (void)sceneDidEnterBackground:(UIScene *)s { front_ios_focus_event(1); }
- (void)sceneWillEnterForeground:(UIScene *)s { front_ios_focus_event(2); }
- (void)sceneDidBecomeActive:(UIScene *)s { front_ios_focus_event(3); }
@end

int main(int argc, char **argv) {
    @autoreleasepool { g_boot_ok = boot_env(); }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
