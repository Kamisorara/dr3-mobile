// iOS front end: selectable native widescreen or fitted 16:9, with a full-screen virtual gamepad.
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#include <errno.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "lan_native.h"

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
void dm_gamepad_set_active(int active);
void front_ios_boot(void);
int front_ios_boot_ok(void);

static CAMetalLayer *g_layer;
static int g_wide,g_metalfx,g_fill,g_aspect;
static CGFloat g_screen_aspect;
static CGRect g_game_frame;   // 游戏画面在 pad view 坐标系里的 rect（触摸透传归一化基准）| game picture rect in pad-view coordinates
void front_ios_configure_display(int wide,int metalfx,int fill) { g_wide=!!wide;g_metalfx=!!metalfx;g_fill=!!fill; }
void front_ios_configure_aspect(int on) {   // 适配模式：渲染分辨率按屏幕比例（参数槽），画面天然铺满
    g_aspect=!!on;
    CGSize nb=UIScreen.mainScreen.nativeBounds.size;
    g_screen_aspect=fmax(nb.width,nb.height)/fmin(nb.width,nb.height);
}
CGRect dm_ios_game_frame(void) { return g_game_frame; }   // DmGamepad 触摸透传读 | consumed by DmGamepad's touch passthrough

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = UIScreen.mainScreen.nativeScale; l.framebufferOnly = NO; l.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    // MetalFX 画布：适配模式按屏幕比例（2560×高），否则 16:9 / 宽屏固定——画布比例必须与
    // layer（=屏幕）一致，否则出图被 aspect-fit 塞进 16:9 画布再拉伸到全屏（iPad 上两侧黑边+变形）。
    // | MetalFX canvas: follow the screen ratio in aspect mode — the canvas must match the layer
    // | (the screen) or the picture is fitted into a 16:9 canvas and then stretched back, leaving
    // | side bars + distortion on the iPad.
    if (g_metalfx) {
        CGFloat h = g_aspect ? round(2560.0 / g_screen_aspect) : (g_wide ? 1176 : 1440);
        l.drawableSize = CGSizeMake(2560, h);
        return;
    }
    // drawable 跟 layer 走但封顶 2560 宽（宽高比不变、无拉伸）：游戏本身 ≤1600×900，再高的分辨率只是
    // 把同一段画面放大；不封顶的话填充模式（layer 比屏幕大）和大屏 fit 模式都会造出巨型缓冲白占显存。
    // | The drawable follows the layer but is capped at 2560 wide (same aspect, no distortion): the game
    // | renders at <=1600x900, so anything higher only upscales; uncapped, fill mode (layer larger than
    // | the screen) and large fitted layers would allocate huge buffers for pixels nobody sees sharper.
    CGSize s = CGSizeMake(round(self.bounds.size.width*l.contentsScale), round(self.bounds.size.height*l.contentsScale));
    if (s.width > 2560) { s = CGSizeMake(2560, round(s.height*2560.0/s.width)); }
    l.drawableSize = s;
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@end
@implementation DmRootVC {
    UILabel *snapLabel;   // 内存快照导出进度浮窗（宿主 hudmove 提供；一次性校准数据采集）
    NSTimer *snapTimer;
    BOOL snapSawActive, snapShownDone;   // 见过「进行中」才展示「完成」（历史 done 的启动不弹窗）
}
- (void)snapTick {   // 每秒问宿主要状态：未触发不显示、进行中显示百分比、完成显示 10 秒后收场
    if (!snapLabel) return;
    int state = 0; float frac = 0;
    dm_hudmove_snapshot_status(&state, &frac);
    if (state == 1) {
        snapSawActive = YES;
        snapLabel.hidden = NO;
        snapLabel.text = [NSString stringWithFormat:@"内存快照导出中 %d%%（完成后拷回 hud-dump.bin，此期间游戏可能略卡）", (int)(frac * 100)];
    } else if (state == 2) {
        if (snapSawActive && !snapShownDone) {
            snapShownDone = YES; snapLabel.hidden = NO;
            snapLabel.text = @"内存快照完成 ✓  文件 App → DR3Mobile：hud-dump.bin/.idx 拷回电脑";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                snapLabel.hidden = YES; [snapTimer invalidate]; snapTimer = nil;
            });
        } else if (!snapSawActive) {   // 历史已完成：不会再导出，浮窗永不出现，定时器直接停
            [snapTimer invalidate]; snapTimer = nil;
        }
    }
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.text = @"游戏资源尚未准备完整。\n请完成游戏和中文语言包的传输后重开。\n\nGame resources are incomplete. Finish transferring the game and Chinese language pack, then reopen.\n\n文稿目录 / Documents: romfs, aoc";
        [self.view addSubview:lb]; return;
    }
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.game];
    g_layer = (CAMetalLayer *)self.game.layer;
    self.pad = dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pad];
    // 快照进度浮窗：顶部中央、半透明黑底白字、不挡触摸（hud-dump.done 已存在时宿主直接报 2，浮窗闪一下完成提示即撤）
    snapLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width - 24, 34)];
    snapLabel.center = CGPointMake(self.view.bounds.size.width / 2, 0);
    snapLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    snapLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    snapLabel.textColor = UIColor.whiteColor; snapLabel.textAlignment = NSTextAlignmentCenter;
    snapLabel.layer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72].CGColor;
    snapLabel.layer.cornerRadius = 8; snapLabel.layer.masksToBounds = YES;
    snapLabel.hidden = YES; snapLabel.userInteractionEnabled = NO;
    // 贴着安全区顶（布局回调里再校正 y）
    [self.view addSubview:snapLabel];
    snapTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(snapTick) userInfo:nil repeats:YES];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; if (!self.game) return;
    snapLabel.center = CGPointMake(b.size.width / 2, self.view.safeAreaInsets.top + 8 + snapLabel.bounds.size.height / 2);
    CGFloat w = b.size.width, h = b.size.height;
    CGFloat aspect=g_aspect?g_screen_aspect:g_wide?1568.0/720.0:16.0/9.0;
    // Fill the matching Air panel; preserve geometry on differently shaped iPads.
    // 适配模式的比例 = 屏幕比例 → fit 计算天然铺满整屏（零黑边零裁切）。
    if(!g_aspect && (!g_wide || fabs(w/h/aspect-1.0)>=0.01)) {
        if(w/h>aspect)w=h*aspect;else h=w/aspect;
    }
    // 填充模式：16:9 画面放大到铺满（cover），超出屏幕的边缘被裁掉——iPad（约 1.44:1）裁左右各约一成，
    // 比上下黑边少占约 30% 屏幕面积。画面内容仍按 16:9 渲染，只是显示几何变化。
    // | Fill mode: scale the 16:9 picture up to cover the screen; overflow is cropped — on an
    // | iPad (~1.44:1) that trims about a tenth off each side. The render stays native 16:9;
    // | only the presentation geometry changes.
    if(g_fill) { CGFloat s=fmax(b.size.width/w,b.size.height/h); w*=s; h*=s; }
    self.game.frame = CGRectMake(floor((b.size.width - w) / 2), floor((b.size.height - h) / 2), w, h);
    g_game_frame = self.game.frame;
}
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; front_ios_boot(); }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // Edge gestures need two swipes, to avoid accidental exits
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
UIViewController *front_ios_root(void) { return [DmRootVC new]; }

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
// 适配模式：KRES 参数槽给「高 720、宽按屏幕比例」——游戏按原生比例渲染，UI 投影随尺寸走，
// 画面天然铺满（同 D2R 的参数槽先例：帧比例=屏幕比例，drawable 同比例无变形）。
// | Aspect mode: the KRES slots get height 720 and the width from the screen ratio — the game
// | renders at the native ratio and the picture fills the screen (same precedent as D2R).
uint64_t front_game_res(int docked) {
    if (g_aspect) {
        unsigned w = (unsigned)(720.0 * g_screen_aspect + 0.5);
        return 720ull << 32 | w;
    }
    return g_wide?(720ull<<32|1568):docked?(900ull<<32|1600):(720ull<<32|1280);
}
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    guest_clock_freeze_for(2, 1);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    guest_clock_freeze_for(2, 0);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game (as d2r-mobile does). hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("前端：存档写失败 errno=%d，提示玩家", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG("【红】前端：存档失败提示没有窗口 errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"存储空间不足，进度没有存上。请清理空间后再存档。\nStorage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"存档写入失败（errno %d），进度没有存上。\nSaving failed (errno %d); progress was not saved.", err, err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"存档失败 / Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// the category stays the default SoloAmbient (silent switch and interrupting other apps' audio behave as before). Set once at boot and again on return to the foreground (the system may reset it after an interruption)
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategorySoloAmbient error:&e]) LOG("【红】音频会话类别设不上：%s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("【红】音频会话 I/O 缓冲时长设不上：%s", e.localizedDescription.UTF8String);
    if (![s setActive:YES error:&e]) LOG("【红】音频会话激活失败：%s", e.localizedDescription.UTF8String);
    LOG("音频会话：采样率 %.0f Hz，I/O 缓冲 %.2f ms（要 5 ms）", s.sampleRate, s.IOBufferDuration * 1000);
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed)
void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_set_active(0); dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: dm_lan_suspend(1); dm_focus_set(3); dm_audio_suspend(1); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
        case 2: dm_lan_suspend(0); dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); dm_audio_suspend(0); dm_focus_set(2); break;
        case 3: dm_gamepad_set_active(1); dm_focus_set(1); break;
    }
}
