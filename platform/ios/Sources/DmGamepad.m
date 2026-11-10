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
#import "DmUiPointer.h"
#import "SeasonPanel.h"

extern CGRect dm_ios_game_frame(void);   // front_ios.m：游戏内容区（黑边/安全区已扣）
static DmUip g_uip;                      // UI 指针触点状态机（安卓 UiPointer C 移植）
extern void dm_uipointer_set(int phase, float x, float y, float bx, float by, long long ms, int paired);   // hle_uipointer.c
extern long long dm_ui_owner(void);      // hle_uipointer.c：(gen<<1)|world——安卓 nativeUiOwner 同义

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
static BOOL g_phys;

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
    BOOL _world;
    long long _owner;          // 安卓 semanticOwner：(gen<<1)|world
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

// ---- listener 回调（安卓 D3Activity 匿名 Listener 同位）----
static void l_changed(void *ctx, const DmSemState *st, int cancelled,
                      const int *ids, const float *xs, const float *ys, int n, long long ms) {
    D3TouchUI *s = (__bridge D3TouchUI *)ctx;
    // ① UI 指针通道：raw（未认领）集全量喂（安卓 publishSemanticInput → uiPointer.publish）。
    //    route 给视图归一坐标，换游戏画布归一（安卓用视图域；画布域在 iPad 适配下更准——kb/07 §12 记差异）。
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
    // ② 语义态 → hid（安卓 nativeControls(owner, buttons, lx, ly, rx, ry)）
    uint64_t btn = 0;
    for (size_t i = 0; i < sizeof k_btn_map / sizeof k_btn_map[0]; i++)
        if (st->buttons & k_btn_map[i].mask) btn |= 1ull << k_btn_map[i].key;
    // 闪避方向向量暂走 B_L 探测近似（安卓 nativeEnqueueEvade 未移植，kb/07 §12）
    if (st->evadeN > 0) btn |= 1ull << B_L;
    pthread_mutex_lock(&g_mu);
    g_sem_btn = btn;
    g_touch_btn = btn;
    g_touch_lx = st->lx; g_touch_ly = st->ly;             // 上=正（安卓 centerY-y 同约定）
    g_touch_rx = (int32_t)(s->_aimX * 32767.0f);          // 瞄准拖动 → 虚拟右摇杆（壳侧近似）
    g_touch_ry = (int32_t)(-s->_aimY * 32767.0f);
    pthread_mutex_unlock(&g_mu);
    publish();
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
    // 安卓 D3Activity.Listener.tap：摇杆区轻点 = 合成 down/up 回放进 uiPointer 通道
    D3TouchUI *s = (__bridge D3TouchUI *)ctx;
    (void)owner; (void)snap;
    CGRect f;
    pthread_mutex_lock(&g_mu);
    f = dm_ios_game_frame();
    pthread_mutex_unlock(&g_mu);
    if (f.size.width <= 0 || f.size.height <= 0) f = s.bounds;
    float fx = (float)((x * (double)s.bounds.size.width - (double)f.origin.x) / (double)f.size.width);
    float fy = (float)((y * (double)s.bounds.size.height - (double)f.origin.y) / (double)f.size.height);
    long long oms = 0; DmUipEvent ev;
    if (dm_uip_publish(&g_uip, &id, &fx, &fy, 1, 0, downMs, &oms, &ev))
        dm_uipointer_set(ev.phase, ev.x, ev.y, ev.bx, ev.by, oms, ev.paired);
    if (dm_uip_publish(&g_uip, NULL, NULL, NULL, 0, 0, upMs, &oms, &ev))
        dm_uipointer_set(ev.phase, ev.x, ev.y, ev.bx, ev.by, oms, ev.paired);
}
static void l_pickup(void *ctx, long long token, int phase) {
    (void)ctx; (void)token; (void)phase;   // token 恒 0（nativePickupState 未移植）——静默
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
        _route.touchSlop = 12;                     // iOS 无系统 touchSlop；UIPan 默认量级约定（安卓 ViewConfiguration 同位）
        _route.longPressMs = 500;                  // 安卓 getLongPressTimeout 缺省
        static const DmSemRouteListener ln = { 0, l_changed, l_skills, l_tap, l_pickup };
        _route.ln = &ln;
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
        NSLog(@"[dm] D3 触控面（安卓同构重写：worldControls 显隐 + Route 分配 + 未认领→菜单指针通道）");
    }
    return self;
}

// ---- 安卓 modePoll 同款：owner 轮询 + 拾取态 ----
- (void)modePoll {
    long long owner = dm_ui_owner();
    if (owner != _owner) {
        _owner = owner;
        _world = (owner & 1) != 0;
        dmroute_sync_owner(&_route, owner >> 1, (int)self.bounds.size.width, (int)self.bounds.size.height);   // 换代全释放（安卓 syncSemanticOwner）
        [self rebuild];
    }
    dmroute_set_pickup(&_route, 0);   // 拾取 token 无来源（安卓 nativePickupState 下轮接）→ 拾取钮禁用
}

// ---- 布局重建（安卓 rebuild）----
- (void)rebuild {
    CGRect b = self.bounds;
    UIEdgeInsets safe = self.safeAreaInsets;
    // density：安卓 display density；iOS point≈dp，取 2.0 约定（kb/07 §12）
    dm_semlayout_build(&_lay, (float)b.size.width, (float)b.size.height, 2.0f,
                       (int)safe.left, (int)safe.top, (int)safe.right, (int)safe.bottom,
                       _world && !g_phys, 0.0f, YES);
    dmroute_bind_controls(&_route, _lay.c, _lay.n);
    dmroute_set_pickup(&_route, 0);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    [self rebuildArt];
    [self placeJoy];
    for (int i = 0; i < 6; i++) [self drawPie:i];
    [CATransaction commit];
    dm_hudmove_set_controller((_world && !g_phys) ? 1 : 0);   // HUD 让位随触控面在场切换（现壳接口=binary）
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
        [self buildVisual:i label:[D3TouchUI labelFor:c] icon:[D3TouchUI iconKeyFor:c] dim:c->kind == 4];
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
        float availH = (float)b.size.height - (float)safe.top - (float)safe.bottom;
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

- (void)placeJoy {   // 底座恒显（安卓语义）：静息归布局位，落指跟随（安卓 beginStick center=落点）；旋钮夹在环内
    if (!_joyRing) {
        _joyRing = mkShape(self.layer); _joyRing.fillColor = UIColor.clearColor.CGColor; _joyRing.hidden = YES;
        _joyKnob = mkShape(self.layer); _joyKnob.hidden = YES;
    }
    int j = [self ctrlIdxBySlot:-1 kind:0];
    if (j < 0) { _joyRing.hidden = YES; _joyKnob.hidden = YES; return; }
    CGFloat R = 123 * _lay.scale;
    CGPoint base = _pos[j];
    if (_route.input.sticks[0].owner)   // 落指跟随：底座=按下点（安卓 beginStick(cx,cy)=触点）
        base = CGPointMake(_route.input.sticks[0].cx, _route.input.sticks[0].cy);
    _joyRing.hidden = NO; _joyKnob.hidden = NO;
    _joyRing.position = base;
    CGPathRef rp = circleAt(CGPointMake(R, R), R); _joyRing.path = rp; CGPathRelease(rp);
    _joyRing.bounds = CGRectMake(0, 0, 2 * R, 2 * R);
    CGFloat kr = 26 * _lay.scale;
    CGPathRef kp = circleAt(CGPointMake(kr, kr), kr); _joyKnob.path = kp; CGPathRelease(kp);
    _joyKnob.bounds = CGRectMake(0, 0, 2 * kr, 2 * kr);
    CGFloat dx = 0, dy = 0;
    if (_route.input.sticks[0].owner) {   // 摇杆输出反推位移（够视觉用）
        dx = (CGFloat)_route.input.sticks[0].x / 32767.0 * R * 0.88f;
        dy = -(CGFloat)_route.input.sticks[0].y / 32767.0 * R * 0.88f;
        CGFloat d = hypot(dx, dy);
        if (d > R) { dx *= R / d; dy *= R / d; }
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

- (void)resetTouches {   // 场景焦点切换/物理手柄插入（安卓 cancelTouches 同位）
    dmroute_cancel(&_route, NOW_MS);
    dm_uip_init(&g_uip);
    for (int i = 0; i < 6; i++) _aimHeld[i] = 0;
    _aimX = 0; _aimY = 0;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = 0; g_touch_lx = 0; g_touch_ly = 0; g_touch_rx = 0; g_touch_ry = 0;
    pthread_mutex_unlock(&g_mu);
    publish();
    [self refreshArt];
}

- (void)syncVisible {   // 物理手柄插拔入口（保留旧名）：空布局 + 全释放
    [self rebuild];
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
        CGPoint p = [t locationInView:self];
        dmroute_up(&_route, (int)(uintptr_t)t, (float)p.x, (float)p.y, ms);
    }
    dmroute_publish(&_route, 0, (int)self.bounds.size.width, (int)self.bounds.size.height);
    [self refreshArt];
    [self scheduleLongPress];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    (void)ts; (void)e;
    dmroute_cancel(&_route, NOW_MS);
    dmroute_publish(&_route, 1, (int)self.bounds.size.width, (int)self.bounds.size.height);   // uiPointer 发相位 3
    [self refreshArt];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self rebuild];
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
    g_phys = present;
    if (present) { [g_view resetTouches]; dm_input_clear(); }
    dm_hudmove_set_controller(present);   // HUD 移位随物理手柄插拔切换（用户确认的还原约束）
    [g_view syncVisible];
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
