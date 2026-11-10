// D3 触控操作面 —— 安卓 SemanticControlsView+D3Activity 触控栈同构重写（2026-11-10 触控重构轮，kb/07 §12）。
// 架构对齐安卓（逐类移植，iOS 只换 UIKit 皮）：
//   分发 = 本视图全时接收（永不 hidden，安卓 Activity.dispatchTouchEvent 同义）；显隐 = 游戏回传
//   worldControls 位（hle_uipointer.c dm_ui_owner，安卓 nativeUiOwner 同源谓词）——world=0 时布局
//   为空数组、触点全落 raw → UI 指针通道（安卓菜单可点的机制本体）。
//   布局 = DmSemanticLayout（安卓 Layout 引擎忠实移植：右组 1851×849 锚右下、摇杆锚左+groupTop、
//   弧 5 键 slots{5,0,3,1,4} 轨道 220 角 180°+32.5°i）。
//   分配 = DmSemanticRoute（安卓 Route：Owner 表/认领/换代全释放/摇杆轻点 350ms 透传）。
//   输入 = DmSemanticInput（安卓 SemanticInput：死区 0.12 线性 remap——旧 0.72 饱和点系误读已纠）。
//   瞄准 = DmSkillAim 事件 + 壳侧近似提交（安卓 nativeSkillAim 链未移植，kb/07 §12 边界）。
// 菜单触点 = 未认领集 → DmUiPointer（安卓 UiPointer C 移植，已有）→ dm_uipointer_set。
// 渲染 = 安卓 ControlArt 矢量嵌槽 + DmTouchSkin PNG + 冷却饼（-90° 顺时针、r=0.86×halfW）。
// 键位 = 安卓按钮掩码映射：1=A 2=B 4=X 8=Y 128=药(R) 256=ZL 512=ZR 1024=包(+) 2048=单(−) 16384=城(DPad右)。
// 赛钮 = 壳自加（安卓无此物）：顶排最左，常显可点（赛季开关的入口，kb/17 E 层）。
// | Touch overlay — same-structure rewrite of the Android touch stack: SemanticControlsView shape
// | (Layout/Route/SemanticInput/SkillAim ports), visibility driven by the game's worldControls
// | bit, unclaimed touches forwarded to the menu pointer channel.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <math.h>
#include <string.h>
#include "dm_input.h"
#include "game_profile.h"
#import "DmSemanticLayout.h"
#import "DmSemanticRoute.h"
#import "DmTouchSkin.h"
#import "DmTouchSlots.h"
#import "DmUiPointer.h"
#import "SeasonPanel.h"

extern CGRect dm_ios_game_frame(void);   // front_ios.m：游戏内容区（黑边/安全区已扣）
static DmUip g_uip;                      // UI 指针触点状态机（安卓 UiPointer C 移植）
extern void dm_uipointer_set(int phase, float x, float y, float bx, float by, long long ms, int paired);   // hle_uipointer.c
extern long long dm_ui_owner(void);      // hle_uipointer.c：(gen<<1)|world——安卓 nativeUiOwner 同义
extern void dm_touch_set(int n, const int *slots, const float *xs, const float *ys);   // hle_uipointer.c：安卓 .so dm_touch_set 同名同义（16 槽状态机）

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
void dm_gamepad_start(void (*on_present)(int present));
void dm_physical_gamepad_reset(void);
extern void dm_hudmove_set_controller(int present);
static uint64_t g_sem_btn;   // 最近一次 changed_at 的语义按钮位图（skills 回调重合 aim 键用）
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// 壳内键号（= hid Npad 位序）：技能槽经 DM_SKILL_SLOT_KEY（0:Y 1:B 2:A 3:X 4:ZL 5:ZR）
enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS,
       B_LEFT, B_UP, B_RIGHT, B_DOWN, B_SEASON, B_PICKUP, B_N };
#define SEASON_IDX 16   // art 下标：赛钮（壳自加，不入 Layout）

// 技能槽 → 键号（kb/07 §9.1 实证表：0:Y 1:B 2:A 3:X 4:ZL 5:ZR；宏原居已退役的 DmTouchLayout.h）
#define DM_SKILL_SLOT_KEY(slot)     ((slot) == 0 ? B_Y : (slot) == 1 ? B_B : (slot) == 2 ? B_A :      (slot) == 3 ? B_X : (slot) == 4 ? B_ZL : (slot) == 5 ? B_ZR : -1)

// 安卓按钮掩码 → 键号（安卓 SemanticInput.buttons 的 nativeControls 喂法）
static const struct { unsigned long long mask; int key; } k_btn_map[] = {
    { 1ull, B_A }, { 2ull, B_B }, { 4ull, B_X }, { 8ull, B_Y },
    { 256ull, B_ZL }, { 512ull, B_ZR }, { 128ull, B_R }, { 16384ull, B_RIGHT },
    { 1024ull, B_PLUS }, { 2048ull, B_MINUS },
};

#define NOW_MS ((long long)(CACurrentMediaTime() * 1000.0))   // 单调毫秒（安卓 uptimeMillis 同义）

@interface D3TouchUI : UIView
@end
static __weak D3TouchUI *g_view;

static UIColor *k_idle, *k_on, *k_line, *k_text, *k_ring, *k_pie;
static inline CAShapeLayer *mkShape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.25; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static inline CATextLayer *mkLabel(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor;
    t.contentsScale = parent.contentsScale;
    [parent addSublayer:t]; return t;
}
static inline CGPathRef circleAt(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef piePath(CGPoint c, CGFloat r, float frac) {   // 冷却遮罩：正上起顺时针扫剩余比例（安卓同款几何）
    if (frac <= 0) return NULL;
    if (frac > 1) frac = 1;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, c.x, c.y);
    CGPathAddArc(p, NULL, c.x, c.y, r, -M_PI_2, -M_PI_2 + 2 * (CGFloat)M_PI * frac, NO);
    CGPathCloseSubpath(p); return p;
}



@implementation D3TouchUI {
    DmSemRoute _route;
    DmSemLayout _lay;
    DmSemRouteListener _ln;   // ctx=self（listener 回调的接收者；位置初始化漏 ctx=崩溃，2026-11-10 真机实证）
    DmTouchSlots _slots;      // 安卓 TouchSlots：raw 触点 → 稳定槽号（nativeTouch 契约）
    BOOL _world;
    long long _owner;          // 安卓 semanticOwner：(gen<<1)|world
    BOOL _menuPrevValid; float _menuPrevX, _menuPrevY;   // 菜单光标：主指上一拍位置（速度=位移×增益）
    int _aPulse;               // 交互 A 脉冲（拾取钮按下=攻击键短按，D3 主机版攻击键兼交互）
    CATextLayer *_fpsLab; CADisplayLink *_link; int _fpsFrames; double _fpsLastT;   // M8 性能浮层（安卓 PerformanceOverlay 轻量版）
    // 渲染（下标 = 布局控件下标 0..15 + SEASON_IDX）
    CGPoint _pos[17]; CGFloat _rad[17]; BOOL _built[17];
    CAShapeLayer *_fill[17], *_ro[17], *_rm[17], *_ri[17], *_tick[17], *_hi[17];
    CATextLayer *_lab[17];
    CALayer *_icon[17];
    CAShapeLayer *_pie[6];
    CAShapeLayer *_joyRing, *_joyKnob;
    float _cdFrac[6];
    int _aimHeld[6]; float _aimX, _aimY;   // 壳侧近似瞄准（安卓 nativeSkillAim 链未移植）
    NSTimer *_poll, *_lp;
}

// ---- 安卓 ControlSkin.iconKey / controlLabel 语义 ----
+ (NSString *)iconKeyFor:(const DmSemControl *)c {
    if (c->slot >= 0) return [NSString stringWithFormat:@"skill%d", c->slot + 1];   // 通用图（动态映射下轮接）
    switch (c->kind) {
        case 3: return @"evade"; case 4: return @"pickup";
        default: break;
    }
    switch (c->button) {
        case 128ull: return @"potion"; case 16384ull: return @"portal";
        case 1024ull: return @"inventory"; case 2048ull: return @"menu";
        default: return nil;
    }
}
+ (NSString *)labelFor:(const DmSemControl *)c {
    if (c->slot >= 0) return c->slot == 2 ? @"攻" : [NSString stringWithFormat:@"%d", c->slot + 1];
    switch (c->kind) {
        case 3: return @"闪"; case 4: return @"拾";
        default: break;
    }
    switch (c->button) {
        case 128ull: return @"药"; case 16384ull: return @"城";
        default: return nil;
    }
}

// ---- 安卓 D3Activity.publishSemanticInput 同构（三通道扇出）----
// ① uiPointer.publish（raw 集，两域都喂——安卓同款，世界/菜单分域在消费端）
// ② cancelled → touchSlots.clear + nativeTouch(0)（dm_touch_set 空）+ nativeCancelButtons（语义清零）
// ③ touchSlots.retain + 槽位映射 → dm_touch_set（安卓 nativeTouch(count, slots, xs, ys)，视图归一域）
// ④ nativeControls：语义按钮/双杆 → hid 触控通道（安卓 .so 侧 d3_touch_controls_set 的宿主等价）
static void publish_semantic(D3TouchUI *s, const DmSemState *st, int cancelled,
                             const int *ids, const float *xs, const float *ys, int n, long long ms) {
    // ① UI 指针通道：坐标换游戏画布归一（安卓用视图域；画布域在 iPad 适配下更准——kb/07 §12 记差异）
    CGRect f;
    pthread_mutex_lock(&g_mu);
    f = dm_ios_game_frame();
    pthread_mutex_unlock(&g_mu);
    if (f.size.width <= 0 || f.size.height <= 0) f = s.bounds;
    int uids[16]; float uxs[16], uys[16]; int un = 0;
    for (int i = 0; i < n && un < 16; i++) {
        uids[un] = ids[i];
        uxs[un] = (float)((xs[i] * (double)s.bounds.size.width - (double)f.origin.x) / (double)f.size.width);
        uys[un] = (float)((ys[i] * (double)s.bounds.size.height - (double)f.origin.y) / (double)f.size.height);
        un++;
    }
    long long oms = 0; DmUipEvent ev;
    if (dm_uip_publish(&g_uip, uids, uxs, uys, un, cancelled, ms, &oms, &ev))
        dm_uipointer_set(ev.phase, ev.x, ev.y, ev.bx, ev.by, oms, ev.paired);
    // ② cancelled：槽全清 + 空触点集 + 语义清零（安卓 publishSemanticInput cancelled 分支）
    if (cancelled) {
        dmts_clear(&s->_slots);
        dm_touch_set(0, NULL, NULL, NULL);
        pthread_mutex_lock(&g_mu);
        g_touch_btn = 0; g_touch_lx = 0; g_touch_ly = 0; g_touch_rx = 0; g_touch_ry = 0;
        pthread_mutex_unlock(&g_mu);
        publish();
        return;
    }
    // ③ 槽位分配 → dm_touch_set（视图归一域，安卓 nativeTouch 同参）
    dmts_retain(&s->_slots, ids, n);
    int tslots[16]; float txs[16], tys[16]; int tn = 0;
    for (int i = 0; i < n && tn < 16; i++) {
        int slot = dmts_slot(&s->_slots, ids[i]);
        if (slot >= 0) { tslots[tn] = slot; txs[tn] = xs[i]; tys[tn] = ys[i]; tn++; }
    }
    dm_touch_set(tn, tslots, txs, tys);
    // M1/M2（安卓 world pump 的壳侧功能等价）：
    //   世界态 raw 触点 = 点地走路（触点相对角色锚的方向 → 虚拟左摇杆；摇杆占用时摇杆优先）；
    //   菜单态 raw 触点拖动 = 右摇杆光标（位移×增益；游戏菜单=右摇杆驱动指针+确认）。
    int32_t walk_x = 0, walk_y = 0, cur_x = 0, cur_y = 0;
    if (n > 0) {
        float vx = xs[0], vy = ys[0];
        if (s->_world) {
            if (!s->_route.input.sticks[0].owner) {
                // 角色锚 = 游戏画布内 (0.5, 0.62)（D3 相机角色略低于屏中），换回视图归一域
                float ax = (float)((f.origin.x + f.size.width * 0.50) / (double)s.bounds.size.width);
                float ay = (float)((f.origin.y + f.size.height * 0.62) / (double)s.bounds.size.height);
                float dx = vx - ax, dy = vy - ay;
                float dist = sqrtf(dx * dx + dy * dy);
                if (dist > 0.07f) {   // 7% 视图死区（防手抖）
                    float m = dist > 0.22f ? 1.0f : dist / 0.22f;   // 22% 视图 = 满推
                    walk_x = (int32_t)(dx / dist * m * 32767.0f);
                    walk_y = (int32_t)(-dy / dist * m * 32767.0f);  // 上=正（hid 约定）
                }
            }
        } else {
            if (s->_menuPrevValid) {
                float dx = vx - s->_menuPrevX, dy = vy - s->_menuPrevY;
                float norm = sqrtf(dx * dx + dy * dy);
                if (norm > 1e-5f) {
                    float cap = 0.12f;   // 单拍位移上限（跳帧防护）
                    if (norm > cap) { dx *= cap / norm; dy *= cap / norm; norm = cap; }
                    float gain = 8.0f;   // 光标速度增益（真机可调）
                    cur_x = (int32_t)(dx / cap * gain * 32767.0f);
                    cur_y = (int32_t)(dy / cap * gain * 32767.0f);
                }
            }
            s->_menuPrevX = vx; s->_menuPrevY = vy; s->_menuPrevValid = YES;
        }
    } else {
        s->_menuPrevValid = NO;
    }
    // ④ nativeControls（安卓语义态直发）
    uint64_t btn = 0;
    for (size_t i = 0; i < sizeof k_btn_map / sizeof k_btn_map[0]; i++)
        if (st->buttons & k_btn_map[i].mask) btn |= 1ull << k_btn_map[i].key;
    // 闪避 = L3 瞬时脉冲（evadeN 一次排空 → 一拍；安卓原生链走游戏内部闪避命令，
    // 键位等价先行，真机校准后可换 kb/11 权威位）——DM_BTN_LS=bit4=硬件 0x10=l3
    if (st->evadeN > 0) btn |= 1ull << B_LS;
    pthread_mutex_lock(&g_mu);
    g_sem_btn = btn;
    g_touch_btn = btn;
    g_touch_lx = st->lx ? st->lx : walk_x;                // 摇杆占用优先，否则点地走路
    g_touch_ly = st->lx || st->ly ? st->ly : walk_y;
    if (!s->_world) { g_touch_rx = cur_x; g_touch_ry = cur_y; }   // 菜单光标（世界态 rx/ry=瞄准，l_skills 管）
    else { g_touch_rx = (int32_t)(s->_aimX * 32767.0f); g_touch_ry = (int32_t)(-s->_aimY * 32767.0f); }
    pthread_mutex_unlock(&g_mu);
    publish();
}

// ---- listener 回调（安卓 D3Activity 匿名 Listener 同位）----
static void l_changed(void *ctx, const DmSemState *st, int cancelled,
                      const int *ids, const float *xs, const float *ys, int n, long long ms) {
    publish_semantic((__bridge D3TouchUI *)ctx, st, cancelled, ids, xs, ys, n, ms);
}
static void l_skills(void *ctx, long long owner, const DmAimEvent *ev, int n, int w, int h, int cancelled) {
    D3TouchUI *s = (__bridge D3TouchUI *)ctx;
    (void)owner; (void)w; (void)h;
    for (int i = 0; i < n; i++) {
        int slot = ev[i].slot;
        if (slot < 0 || slot >= 6) continue;
        switch (ev[i].phase) {
            case 0: case 4: s->_aimHeld[slot] = 1; break;          // down/hold：绑定键保持
            case 2: case 3: s->_aimHeld[slot] = 0; break;          // up/cancel
            case 1:
                if (ev[i].dragged) {                                // 拖动向量 → 归一方向（安卓原版 native 侧算 rx,ry）
                    s->_aimX = (ev[i].x - ev[i].ox) / ev[i].radius;
                    s->_aimY = (ev[i].y - ev[i].oy) / ev[i].radius;
                    if (s->_aimX > 1) s->_aimX = 1; if (s->_aimX < -1) s->_aimX = -1;
                    if (s->_aimY > 1) s->_aimY = 1; if (s->_aimY < -1) s->_aimY = -1;
                }
                break;
        }
    }
    if (cancelled) {   // 安卓 skillPublisher.cancel：全清
        for (int i = 0; i < 6; i++) s->_aimHeld[i] = 0;
        s->_aimX = 0; s->_aimY = 0;
    }
    pthread_mutex_lock(&g_mu);
    uint64_t btn = g_sem_btn;                              // 重合 aim 键（最后一次 publish 也不能卡按下态）
    for (int slot = 0; slot < 6; slot++)
        if (s->_aimHeld[slot]) btn |= 1ull << [D3TouchUI slotKey:slot];
    g_touch_btn = btn;
    g_touch_rx = (int32_t)(s->_aimX * 32767.0f);
    g_touch_ry = (int32_t)(-s->_aimY * 32767.0f);
    pthread_mutex_unlock(&g_mu);
    publish();
}
static void l_tap(void *ctx, long long owner, int id, float x, float y,
                  long long downMs, long long upMs, const DmSemState *snap) {
    // 安卓 D3Activity.Listener.tap：摇杆轻点 = 两段完整发布（down 时刻该指独占 raw 集 →
    // up 时刻空集），同走 publishSemanticInput 三通道（uiPointer + 槽位 + 语义态）。
    D3TouchUI *s = (__bridge D3TouchUI *)ctx;
    (void)owner;
    publish_semantic(s, snap, 0, &id, &x, &y, 1, downMs);
    publish_semantic(s, snap, 0, NULL, NULL, NULL, 0, upMs);
}
static void l_pickup(void *ctx, long long token, int phase) {
    (void)ctx; (void)token;
    // M5：拾取钮 = 攻击键短按（D3 主机版攻击键兼交互/拾取；安卓原生链走 loot 查询+edge，
    // 壳侧等价先行）。phase 0=按下沿 → 2 个 poll tick 的 A 脉冲（~100ms）。
    if (phase == 0) { D3TouchUI *s = (__bridge D3TouchUI *)ctx; s->_aPulse = 2; }
}

// ---- 键位映射 ----
+ (int)slotKey:(int)slot { return DM_SKILL_SLOT_KEY(slot); }   // 槽 → 键号（0:Y 1:B 2:A 3:X 4:ZL 5:ZR）

- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 字号单位（真机已验证量级）

- (void)applySkillAtlas:(const unsigned char *)rgba w:(int)w h:(int)h {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate((void *)rgba, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return;
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFRelease(ctx);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    // 图集管线仍暂停中（接口保留）：切 6 份给槽图标
    for (int k = 0; k < 6; k++) {
        CALayer *dst = _icon[[D3TouchUI slotKey:k]];
        if (!dst) continue;
        CGImageRef sub = CGImageCreateWithImageInRect(img, CGRectMake(k * w / 6.0, 0, w / 6.0, h));
        dst.contents = (__bridge id)sub;
        CGImageRelease(sub);
    }
    [CATransaction commit];
    CGImageRelease(img);
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        dmroute_init(&_route);
        _route.touchSlop = 8;                      // 安卓 ViewConfiguration 缺省 8dp（iOS 无系统值，dp≈pt）
        _route.longPressMs = 500;                  // 安卓 getLongPressTimeout 缺省
        dmts_init(&_slots);
        _ln.ctx = (__bridge void *)self;
        _ln.changed_at = l_changed; _ln.skills = l_skills; _ln.tap = l_tap; _ln.pickup = l_pickup;
        _route.ln = &_ln;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            k_idle = [UIColor colorWithWhite:0.05 alpha:0.55]; k_on = [UIColor colorWithWhite:0.24 alpha:0.85];
            k_line = [UIColor colorWithWhite:0.62 alpha:0.5]; k_text = [UIColor colorWithWhite:0.96 alpha:1];
            k_ring = [UIColor colorWithWhite:1 alpha:0.28];
            k_pie = [UIColor colorWithRed:0.788 green:0 blue:0 alpha:0.788];   // #C9000000
        });
        // 安卓：面永不停止接收——world=0 时布局为空、触点全落菜单通道（本视图永不 hidden）
        _world = NO; _owner = -1;
        __weak typeof(self) wself = self;
        _poll = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {   // 安卓 modePoll 100ms
            __typeof__(self) s = wself; if (!s) { [t invalidate]; return; }
            [s modePoll];
        }];
        [[NSRunLoop mainRunLoop] addTimer:_poll forMode:NSRunLoopCommonModes];
        // M8 性能浮层（安卓 PerformanceOverlay 轻量等价：fps + 帧时长，左上角常显）
        _fpsLab = [CATextLayer layer];
        _fpsLab.fontSize = 11; _fpsLab.alignmentMode = kCAAlignmentLeft;
        _fpsLab.foregroundColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
        _fpsLab.contentsScale = [UIScreen mainScreen].scale ?: 2;
        _fpsLab.frame = CGRectMake(8, 34, 160, 16);
        [self.layer addSublayer:_fpsLab];
        _fpsLastT = CACurrentMediaTime();
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(fpsFrame:)];
        [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        NSLog(@"[dm] D3 触控面（安卓同构重写：worldControls 显隐 + Route 分配 + 未认领→菜单指针通道）");
    }
    return self;
}

- (void)fpsFrame:(CADisplayLink *)lk {   // M8：帧计数 → 0.5s 窗口 fps/帧时长
    _fpsFrames++;
    double now = lk.timestamp;
    double dt = now - _fpsLastT;
    if (dt >= 0.5) {
        double fps = _fpsFrames / dt;
        _fpsLab.string = [NSString stringWithFormat:@"%.0f fps  %.1f ms", fps, 1000.0 / fps];
        _fpsFrames = 0; _fpsLastT = now;
    }
}

// ---- 安卓 syncSemanticOwner：owner 变化 → 全释放 + 世界位切换 + rebuild（dispatch/began 时也调）----
- (void)syncOwner {
    long long owner = dm_ui_owner();
    if (owner == _owner) return;
    _owner = owner;
    _world = (owner & 1) != 0;
    dmroute_sync_owner(&_route, owner >> 1, (int)self.bounds.size.width, (int)self.bounds.size.height);   // 换代全释放（安卓 syncSemanticOwner→setWorldControls）
    [self rebuild];
}

// ---- 安卓 modePoll 同款：owner 轮询 + 拾取态 + 交互脉冲 ----
- (void)modePoll {
    [self syncOwner];
    dmroute_set_pickup(&_route, 1);   // 拾取钮常启用（token 语义 = 安卓 loot 查询待接；按下→A 脉冲）
    if (_aPulse == 2) {               // 拾取/交互：A 按下 tick → 释放 tick（~100ms 脉冲）
        pthread_mutex_lock(&g_mu);
        g_touch_btn |= 1ull << B_A;
        pthread_mutex_unlock(&g_mu);
        publish();
    } else if (_aPulse == 1) {
        pthread_mutex_lock(&g_mu);
        g_touch_btn &= ~(1ull << B_A);
        pthread_mutex_unlock(&g_mu);
        publish();
    }
    if (_aPulse) _aPulse--;
}

// ---- 布局重建（安卓 rebuild）----
- (void)rebuild {
    CGRect b = self.bounds;
    UIEdgeInsets safe = self.safeAreaInsets;
    // density：安卓 display density（px/dp）；iOS 等价 = 屏幕 nativeScale（pt→px）
    CGFloat density = self.window.screen.nativeScale;
    if (density <= 0) density = [UIScreen mainScreen].nativeScale;
    if (density <= 0) density = 2.0;
    dm_semlayout_build(&_lay, (float)b.size.width, (float)b.size.height, (float)density,
                       (int)safe.left, (int)safe.top, (int)safe.right, (int)safe.bottom,
                       _world, 0.0f, YES);
    dmroute_bind_controls(&_route, _lay.c, _lay.n);
    dmroute_set_pickup(&_route, 1);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [self rebuildArt];
    [self placeJoy];
    for (int i = 0; i < 6; i++) [self drawPie:i];
    [CATransaction commit];
    dm_hudmove_set_controller(_world ? 1 : 0);   // HUD 让位 = worldControls（安卓 RoleControlGeometryBridge 语义的二元版；物理柄不再影响——2026-11-10 完全照搬轮）
}

- (int)ctrlIdxBySlot:(int)slot kind:(int)kind {
    for (int i = 0; i < _lay.n; i++)
        if (_lay.c[i].kind == kind && (slot < 0 || _lay.c[i].slot == slot)) return i;
    return -1;
}
- (int)ctrlIdxByButton:(unsigned long long)btn {
    for (int i = 0; i < _lay.n; i++)
        if (_lay.c[i].button == btn) return i;
    return -1;
}

// ---- 渲染：布局控件 → art 层（沿用已验证的 ControlArt 嵌槽）----
- (void)buildVisual:(int)idx label:(NSString *)text icon:(NSString *)iconKey dim:(BOOL)dim {
    CGPoint c = _pos[idx]; CGFloat r = _rad[idx];
    if (!_fill[idx]) {
        _fill[idx] = mkShape(self.layer);
        _ro[idx] = mkShape(self.layer); _ro[idx].fillColor = nil;
        _rm[idx] = mkShape(self.layer); _rm[idx].fillColor = nil; _rm[idx].strokeColor = k_ring.CGColor;
        _ri[idx] = mkShape(self.layer); _ri[idx].fillColor = nil;
        _tick[idx] = mkShape(self.layer); _tick[idx].fillColor = nil; _tick[idx].strokeColor = k_ring.CGColor;
        _hi[idx] = mkShape(self.layer); _hi[idx].fillColor = nil; _hi[idx].hidden = YES;
        _hi[idx].strokeColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
    }
    CGPathRef p = circleAt(c, r); _fill[idx].path = p; _fill[idx].shadowPath = p; CGPathRelease(p);
    CGFloat scale = self.window.screen.scale ?: 2;
    _ro[idx].lineWidth = fmax(1, 0.016 * r); _rm[idx].lineWidth = fmax(1, 0.03 * r);
    _ri[idx].lineWidth = fmax(1, 0.012 * r); _hi[idx].lineWidth = fmax(1, 0.025 * r);
    CGPathRef po = circleAt(c, r * 0.982); _ro[idx].path = po; CGPathRelease(po);
    CGPathRef pm = circleAt(c, r * 0.956); _rm[idx].path = pm; CGPathRelease(pm);
    CGPathRef pi_ = circleAt(c, r * 0.929); _ri[idx].path = pi_; CGPathRelease(pi_);
    CGPathRef ph = circleAt(c, r * 0.925); _hi[idx].path = ph; CGPathRelease(ph);
    CGMutablePathRef tp = CGPathCreateMutable();
    for (int q = 0; q < 4; q++) {   // 45°/135°/225°/315° 刻度线（r0.944→0.97）
        CGFloat a = (q * 0.5 + 0.25) * (CGFloat)M_PI;
        CGPathMoveToPoint(tp, NULL, c.x + r * 0.944 * cos(a), c.y + r * 0.944 * sin(a));
        CGPathAddLineToPoint(tp, NULL, c.x + r * 0.97 * cos(a), c.y + r * 0.97 * sin(a));
    }
    _tick[idx].path = tp; _tick[idx].lineWidth = fmax(1, 0.008 * r); CGPathRelease(tp);
    _fill[idx].contentsScale = _ro[idx].contentsScale = _rm[idx].contentsScale = _ri[idx].contentsScale = scale;
    _tick[idx].contentsScale = _hi[idx].contentsScale = scale;
    _fill[idx].opacity = dim ? 0.45f : 1.0f;   // 拾取钮灰显（token 无来源）
    UIImage *img = iconKey ? [DmTouchSkin.shared image:iconKey] : nil;
    if (img) {
        if (!_icon[idx]) { _icon[idx] = [CALayer layer]; _icon[idx].contentsGravity = kCAGravityResizeAspect; _icon[idx].masksToBounds = YES; [_fill[idx].superlayer insertSublayer:_icon[idx] above:_fill[idx]]; }
        _icon[idx].frame = CGRectMake(c.x - r * 0.82, c.y - r * 0.82, r * 1.64, r * 1.64);
        _icon[idx].cornerRadius = r * 0.82;
        _icon[idx].contents = (__bridge id)img.CGImage;
        _icon[idx].contentsScale = scale;
        _icon[idx].hidden = NO;
        if (_lab[idx]) _lab[idx].hidden = YES;
    } else {
        if (_icon[idx]) _icon[idx].hidden = YES;
        if (text && !_lab[idx]) _lab[idx] = mkLabel(_fill[idx], text);
        if (_lab[idx]) {
            CGFloat fs = [text isEqualToString:@"攻"] ? 22 * self.u : 14 * self.u;
            _lab[idx].fontSize = fs;
            _lab[idx].frame = CGRectMake(c.x - fs * 1.6, c.y - fs * 0.75, fs * 3.2, fs * 1.5);
            _lab[idx].contentsScale = scale;
            _lab[idx].hidden = NO;
        }
    }
}

- (void)rebuildArt {
    for (int i = 0; i < _lay.n; i++) {
        DmSemControl *c = &_lay.c[i];
        _pos[i] = CGPointMake(c->x, c->y); _rad[i] = c->halfW; _built[i] = YES;
        _fill[i].hidden = NO;
        [self buildVisual:i label:[D3TouchUI labelFor:c] icon:[D3TouchUI iconKeyFor:c] dim:(c->kind == 4 && !c->enabled)];
    }
    for (int i = _lay.n; i < SEASON_IDX; i++) {   // 布局缩空（world=0）：旧 art 全隐
        _built[i] = NO;
        if (_fill[i]) { _fill[i].hidden = YES; if (_icon[i]) _icon[i].hidden = YES; if (_lab[i]) _lab[i].hidden = YES; }
    }
    [self buildSeason];
}

- (void)buildSeason {   // 赛钮 = 壳自加（安卓无）：顶排“包”左侧同高；world=0 也常显（赛季开关入口）
    CGRect b = self.bounds; UIEdgeInsets safe = self.safeAreaInsets;
    int bag = [self ctrlIdxByButton:1024ull];
    CGFloat s = _lay.scale > 0 ? _lay.scale : MIN(b.size.width / 1851.0, b.size.height / 849.0);
    CGPoint pos; CGFloat r = 42.0 * s;
    if (bag >= 0) pos = CGPointMake(_pos[bag].x - 2 * _rad[bag] - 12 * s, _pos[bag].y);
    else {   // 无布局时按同公式锚定（安卓 menuX/bagX 同款）
        float availW = (float)b.size.width - (float)safe.left - (float)safe.right;
        float minTap = MIN(24.0f * 2.0f, 60.0f * s);
        float topTap = MIN(minTap, 50.0f * s), topHit = MAX(42.0f * s, topTap);
        float toolbarLimit = ((float)b.size.width - ((float)b.size.height * 240.0f) / 720.0f) - 1.0f;
        float menuX = MIN(((float)b.size.width - (float)safe.right) - topHit, toolbarLimit - (16.0f * s) - topHit);
        float bagX = menuX - 2.0f * topHit - 12.0f * s;
        pos = CGPointMake(bagX, (float)safe.top + 64.0f * s);
    }
    _pos[SEASON_IDX] = pos; _rad[SEASON_IDX] = r; _built[SEASON_IDX] = YES;
    [self buildVisual:SEASON_IDX label:@"赛" icon:nil dim:NO];
}

- (void)drawPie:(int)slot {
    int idx = [self ctrlIdxBySlot:slot kind:2];
    if (idx < 0 || !_fill[idx]) { if (_pie[slot]) _pie[slot].hidden = YES; return; }
    if (!_pie[slot]) {
        _pie[slot] = [CAShapeLayer layer];
        _pie[slot].fillColor = k_pie.CGColor; _pie[slot].strokeColor = nil; _pie[slot].lineWidth = 0; _pie[slot].hidden = YES;
        [_fill[idx].superlayer insertSublayer:_pie[slot] above:_fill[idx]];
    }
    float frac = _cdFrac[slot];
    _pie[slot].hidden = frac <= 0 || !_world;
    CGPathRef p = piePath(_pos[idx], _rad[idx] * 0.86, frac);   // 安卓：r=0.86×halfW，#C9000000
    _pie[slot].path = p;
    if (p) CGPathRelease(p);
}

- (void)placeJoy {   // 安卓 drawControl(kind0)：底座=落点（stickVisualCoordinate 1.4R 边距夹取），
                     // 旋钮偏移 = lx/32767×halfW×0.53、旋钮半径 = 0.4×halfW（此前 0.88/26s 系自造）
    if (!_joyRing) {
        _joyRing = mkShape(self.layer); _joyRing.fillColor = UIColor.clearColor.CGColor; _joyRing.hidden = YES;
        _joyKnob = mkShape(self.layer); _joyKnob.hidden = YES;
    }
    int j = [self ctrlIdxBySlot:-1 kind:0];
    if (j < 0) { _joyRing.hidden = YES; _joyKnob.hidden = YES; return; }
    CGFloat R = _rad[j];                       // = 123×scale（布局半径即视觉半径）
    UIEdgeInsets safe = self.safeAreaInsets;
    CGPoint base = _pos[j];
    if (_route.input.sticks[0].owner) {        // 落指跟随：底座=按下点，夹在安全区−1.4R 边距内（安卓 ControlArt.stickVisualCoordinate）
        base = CGPointMake(_route.input.sticks[0].cx, _route.input.sticks[0].cy);
        CGFloat m = 1.4 * R;
        CGFloat lo = safe.left + m, hi = self.bounds.size.width - safe.right - m;
        if (lo <= hi) base.x = fmax(lo, fmin(hi, base.x));
        else base.x = (self.bounds.size.width) / 2.0;
        lo = safe.top + m; hi = self.bounds.size.height - safe.bottom - m;
        if (lo <= hi) base.y = fmax(lo, fmin(hi, base.y));
        else base.y = (self.bounds.size.height) / 2.0;
    }
    _joyRing.hidden = NO; _joyKnob.hidden = NO;
    _joyRing.position = base;
    CGPathRef rp = circleAt(CGPointMake(R, R), R); _joyRing.path = rp; CGPathRelease(rp);
    _joyRing.bounds = CGRectMake(0, 0, 2 * R, 2 * R);
    CGFloat kr = 0.4 * R;                      // 安卓 stickThumb r=0.4×halfW
    CGPathRef kp = circleAt(CGPointMake(kr, kr), kr); _joyKnob.path = kp; CGPathRelease(kp);
    _joyKnob.bounds = CGRectMake(0, 0, 2 * kr, 2 * kr);
    CGFloat dx = 0, dy = 0;
    if (_route.input.sticks[0].owner) {        // 旋钮位移 = 状态输出 ×0.53×halfW（安卓 drawControl 同式）
        dx = (CGFloat)_route.input.sticks[0].x / 32767.0 * R * 0.53;
        dy = -(CGFloat)_route.input.sticks[0].y / 32767.0 * R * 0.53;
    }
    _joyKnob.position = CGPointMake(base.x + dx, base.y + dy);
}

- (void)refreshArt {   // 按下态：底填充换亮色 + 按下环（安卓 drawControl held 同效）
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int i = 0; i < _lay.n; i++) {
        if (!_fill[i]) continue;
        BOOL on = _lay.c[i].held > 0;
        _fill[i].fillColor = (on ? k_on : k_idle).CGColor;
        _hi[i].hidden = !on;
    }
    [self placeJoy];
    [CATransaction commit];
}

- (void)cancelTouches {   // 安卓 cancelTouches：只清状态（长按定时器/Route/UIP/槽位/瞄准近似），不 publish——调用方决定
    [_lp invalidate];
    dmroute_cancel(&_route, NOW_MS);
    dm_uip_init(&g_uip);
    dmts_clear(&_slots);
    for (int i = 0; i < 6; i++) _aimHeld[i] = 0;
    _aimX = 0; _aimY = 0;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = 0; g_touch_lx = 0; g_touch_ly = 0; g_touch_rx = 0; g_touch_ry = 0;
    pthread_mutex_unlock(&g_mu);
    [self refreshArt];
}

- (void)resetTouches {   // 焦点丢失/生命周期（安卓 releaseInput）：cancelTouches + publish(true) + nativeTouch(0)
    [self cancelTouches];
    dm_touch_set(0, NULL, NULL, NULL);
    publish();
    dmroute_publish(&_route, 1, (int)self.bounds.size.width, (int)self.bounds.size.height);
}

// ---- 长按（安卓 skillLongPress Runnable 同款：按最紧急手势排定时器）----
- (void)scheduleLongPress {
    [_lp invalidate];
    long long delay = dmroute_next_long_press_delay(&_route, NOW_MS);
    if (delay < 0) return;
    __weak typeof(self) wself = self;
    _lp = [NSTimer timerWithTimeInterval:(delay / 1000.0) repeats:NO block:^(NSTimer *t) {
        __typeof__(self) s = wself; if (!s) return;
        if (dmroute_long_press(&s->_route, NOW_MS)) {
            dmroute_publish(&s->_route, 0, (int)s.bounds.size.width, (int)s.bounds.size.height);
            [s refreshArt];
        }
        [s scheduleLongPress];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_lp forMode:NSRunLoopCommonModes];
}

// ---- 触摸（安卓 SemanticControlsView.onTouchEvent 契约重建）----
- (BOOL)panelOpen {
    for (UIView *v in self.subviews) if ([v isKindOfClass:[SeasonPanel class]]) return YES;
    return NO;
}
- (BOOL)seasonAt:(CGPoint)p {
    return _built[SEASON_IDX] && hypot(p.x - _pos[SEASON_IDX].x, p.y - _pos[SEASON_IDX].y) <= _rad[SEASON_IDX];
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if ([self panelOpen]) return;   // 面板打开 = 安卓 isBlocking：触控面全让
    [self syncOwner];               // 安卓 dispatchTouchEvent：先 syncSemanticOwner 再分发
    long long ms = NOW_MS;
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        if ([self seasonAt:p]) { [SeasonPanel presentInView:self]; continue; }
        int idx = dm_semlayout_hit(&_lay, (float)p.x, (float)p.y);
        dmroute_down(&_route, (int)(uintptr_t)t, idx, (float)p.x, (float)p.y, ms);
    }
    dmroute_publish(&_route, 0, (int)self.bounds.size.width, (int)self.bounds.size.height);
    [self refreshArt];
    [self scheduleLongPress];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if ([self panelOpen]) return;
    long long ms = NOW_MS;
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        dmroute_move(&_route, (int)(uintptr_t)t, (float)p.x, (float)p.y, ms);
    }
    dmroute_publish(&_route, 0, (int)self.bounds.size.width, (int)self.bounds.size.height);
    [self refreshArt];
    [self scheduleLongPress];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    if ([self panelOpen]) return;
    long long ms = NOW_MS;
    for (UITouch *t in ts) {
        // 安卓 UP/POINTER_UP：先终移（最终坐标进 aim/摇杆/轻点判定）再 up
        CGPoint p = [t locationInView:self];
        dmroute_move(&_route, (int)(uintptr_t)t, (float)p.x, (float)p.y, ms);
        dmroute_up(&_route, (int)(uintptr_t)t, ms);
    }
    dmroute_publish(&_route, 0, (int)self.bounds.size.width, (int)self.bounds.size.height);
    [self refreshArt];
    [self scheduleLongPress];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    (void)ts; (void)e;
    [self cancelTouches];   // 安卓 CANCEL 分支：cancelTouches + publish(true)
    dmroute_publish(&_route, 1, (int)self.bounds.size.width, (int)self.bounds.size.height);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 安卓 onSizeChanged：尺寸实际变化才 cancelTouches + rebuild + publish(true)（首布局同走）
    static CGSize last = { -1, -1 };
    CGSize sz = self.bounds.size;
    if (sz.width == last.width && sz.height == last.height) return;
    last = sz;
    [self cancelTouches];
    [self rebuild];
    dmroute_publish(&_route, 1, (int)sz.width, (int)sz.height);
}

// hle 层每帧推 D3 技能冷却（slot = 游戏槽序 0..5；frac∈[0,1] 剩余比例，<0 无冷却）。
// 定义在 @implementation 内：可访问私有 ivar（@end 外访问会报 private，CI 实证）。
void dm_gamepad_skill(int slot, float frac) {
    D3TouchUI *v = g_view;
    if (!v || slot < 0 || slot >= 6) return;
    if (fabsf(v->_cdFrac[slot] - frac) < 0.01f) return;   // 1% 节流
    v->_cdFrac[slot] = frac;
    if ([NSThread isMainThread]) [v drawPie:slot];
    else dispatch_async(dispatch_get_main_queue(), ^{ [v drawPie:slot]; });
}

// nvn_mtl 推技能图标图集（图集管线仍暂停中；接口保留）。
void dm_gamepad_skill_atlas(const unsigned char *rgba, int w, int h) {
    D3TouchUI *v = g_view;
    if (!v || w != 1024 || h != 512 || !rgba) return;
    unsigned char *copy = malloc((size_t)w * 4 * h);
    if (!copy) return;
    memcpy(copy, rgba, (size_t)w * 4 * h);
    dispatch_async(dispatch_get_main_queue(), ^{
        [v applySkillAtlas:copy w:w h:h];
        free(copy);
    });
}
@end

// ---- 外部接口（front_ios / PhysicalGamepad 契约不变） ----
static void physical_present(int present) {
    // 安卓 PhysicalGamepadInput.Sink.connected：仅记录。物理柄（dm_pad_set）与触控（dm_input_set）
    // 是两条独立通道，读取时 OR——手柄在场不再压制触控面/清触控输入（2026-11-10 完全照搬轮，
    // 旧 g_phys 压制 = "技能按钮不见了"的直接根因之一）。
    NSLog(@"[dm] 物理手柄 %d（触控面独立，不受影响）", present);
}
UIView *dm_gamepad_view(CGRect frame) {
    D3TouchUI *v = [[D3TouchUI alloc] initWithFrame:frame];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_view = v;
    dm_gamepad_start(physical_present);
    return v;
}
void dm_gamepad_reset(void) {
    // Called on the UIKit main thread by scene focus transitions.
    [g_view resetTouches];
    dm_input_clear();
    dm_physical_gamepad_reset();
}
