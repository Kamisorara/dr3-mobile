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
void front_ios_configure_display(int wide, int metalfx);
int dr3_lan_supported(void) __attribute__((weak_import));

static char *g_argv[4]; static int g_argc;
static int g_launch_selected;

static NSDictionary *graphics_profile(void) {
    NSString *path=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm/mobile-graphics.json"];
    NSData *data=[NSData dataWithContentsOfFile:path];
    id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    return [value isKindOfClass:NSDictionary.class]?value:@{};
}
static BOOL wide_available(void) {
    NSDictionary *profile=graphics_profile(),*p=profile[@"parameters"];
    return [profile[@"startup_selection"] boolValue] && [profile[@"mode"] isEqual:@"d3-mobile-graphics"] &&
           [p[@"width"] intValue]==1568 && [p[@"height"] intValue]==720;
}

#include "../../../native/asset_inventory.h"

static NSString *romfs_locate(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    for (NSString *d in @[[doc stringByAppendingPathComponent:@"romfs"], [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs"]])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:@DM_GAME_ROMFS_MARKER]]) return d;   // only a directory containing the game profile's romfs_marker path counts (Mario: System/Resource, the resource size table)
    return nil;
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
    NSString *romfs = romfs_locate();
    if (!romfs) { fprintf(stderr, "boot: 没找到游戏文件（<App>/romfs 或 Documents/romfs）\n"); return 0; }
    NSString *aoc = nil;
    for (NSString *candidate in @[[doc stringByAppendingPathComponent:@"aoc"],[res stringByAppendingPathComponent:@"aoc"]]) {
        if ([fm fileExistsAtPath:[candidate stringByAppendingPathComponent:@"11/ztCN_CoreCommon.cpk"]]) { aoc=candidate; break; }
    }
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
- (void)startWide:(BOOL)wide hud:(BOOL)hud metalfx:(BOOL)metalfx lan:(BOOL)lan {
    if(g_launch_selected || !g_boot_ok)return;
    if(wide&&!wide_available())return;
    setenv("MTL_HUD_ENABLED",hud?"1":"0",1);
    setenv("DM_METALFX",metalfx?"spatial":"off",1);
    setenv("DM_IOS_GRAPHICS_MODE",wide?"wide":"normal",1);
    setenv("DM_GAME_RES",wide?"1568x720":"1280x720",1);
    setenv("DM_DR3_LAN",lan?"1":"0",1);
    fprintf(stderr,"boot: launch mode=%s render=%s HUD=%d MetalFX=%s LAN=%d\n",wide?"wide":"normal",getenv("DM_GAME_RES"),hud,metalfx?"spatial":"off",lan);
    front_ios_configure_display(wide,metalfx);
    dm_host_preload_start(g_argc,g_argv);
    g_launch_selected=1;
    self.window.rootViewController=front_ios_root();
    dispatch_async(dispatch_get_main_queue(),^{if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive)front_ios_focus_event(3);});
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    BOOL lan=dr3_lan_supported&&dr3_lan_supported();
    LauncherViewController *launcher=[[LauncherViewController alloc] initWithWideAvailable:wide_available() lanAvailable:lan ready:g_boot_ok reason:@"游戏和中文资源未准备完整，请完成传输后重新打开。"];
    __weak SceneDelegate *weakSelf=self;
    launcher.onPlay=^(BOOL wide,BOOL hud,BOOL metalfx,BOOL lan){[weakSelf startWide:wide hud:hud metalfx:metalfx lan:lan];};
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
