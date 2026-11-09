// D3 触控操作面 —— 完全重写（2026-11-09，替代壳自带虚拟手柄框架）。
// 旧框架的 2D/3D 布局、布局切换器、泪滴/pill 键、菜单态状态机、D-pad/右摇杆全部移除。
// 设计（暗黑不朽式）：
//   左半屏动态摇杆：落指处生成底环，抬手消失——不预画固定环，不再与血球抢左下角；
//   右下固定技能簇：大攻击键(A) + 5 技能弧(X/Y/ZR/L/B) + 药水(R)——键位对照游戏主机默认
//   （HUD 提示：药=R、技能含 ZR）；冷却扇形遮罩由 hle skills_frame 10Hz 推送；
//   顶右系统键排：包(+)、单(−)、城(ZL)。
// 输入 = dm_input_set 真键：A=确认、B=取消、摇杆=导航，游戏菜单天然可用（无需菜单态切换）。
// 显隐 = 进游戏门控 dm_ingame（HUD 根槽，hle_uistate 1Hz）∧ 无物理手柄 ∧ 前台激活。
// | D3-specific touch overlay — full rewrite. DI-style: dynamic left joystick born under the
// | thumb; fixed right cluster (attack + skill arc + potion); top-right system pills.
// | Real HID keys only; visibility gated by dm_ingame / physical pad / front activity.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include "dm_input.h"
#include "game_profile.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_N };
// 本界面只发这些键：A 攻击 / X Y ZR L B 技能弧 / R 药水 / ZL 城 / + 包 / − 单（= NpadButton 位序）

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
void dm_gamepad_start(void (*on_present)(int present));
void dm_physical_gamepad_reset(void);
extern void dm_hudmove_set_controller(int present);
int dm_ingame(void);   // hle_uistate：HUD 根槽非空 = 游戏态
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- 几何常量（单位 u = H/430；右半簇自右下角、系统排自右上角量） ----
static const CGFloat
    K_JOY_ZONE_X = 0.45,     // 摇杆区：屏幕左 45%
    K_JOY_ZONE_Y = 0.16,     //    且 y > 16% 高（避开顶部小地图/任务栏）
    K_JOY_R = 62, K_JOY_KNOB = 26, K_JOY_DEAD = 0.12, K_JOY_FULL = 0.72,
    K_ATK_DX = 92, K_ATK_DY = 128, K_ATK_R = 46,     // 攻击键心距右下角
    K_ARC_R = 88, K_ARC_R_KEY = 27,                  // 技能弧半径/弧键半径
    K_POT_DX = 36, K_POT_DY = 42, K_POT_R = 25,      // 药水键（攻击键右下）
    K_SYS_DY = 150, K_SYS_DX0 = 40, K_SYS_STEP = 48, K_SYS_R = 19;   // 系统排（小地图下方）
static const CGFloat K_ARC_DEG[5] = {108, 136, 164, 192, 220};
static const int    K_ARC_KEY[5] = {B_X, B_Y, B_ZR, B_L, B_B};
static const int    K_CD_KEY[6]  = {B_A, B_X, B_Y, B_ZR, B_L, B_B};   // 冷却槽序 = dm_gamepad_skill 的 slot 序

@interface D3TouchUI : UIView
@end
static __weak D3TouchUI *g_view;
static BOOL g_phys;   // 物理手柄在场（dm_gamepad_set_active/焦点清理由 PhysicalGamepad.m 的物理后端负责）

static UIColor *k_idle, *k_on, *k_line, *k_text;
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
static CGPathRef piePath(CGPoint c, CGFloat r, float frac) {   // 冷却遮罩：正上起顺时针扫剩余比例
    if (frac <= 0) return NULL;
    if (frac > 1) frac = 1;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, c.x, c.y);
    CGPathAddArc(p, NULL, c.x, c.y, r, -M_PI_2, -M_PI_2 + 2 * (CGFloat)M_PI * frac, NO);
    CGPathCloseSubpath(p); return p;
}

@implementation D3TouchUI {
    NSMapTable<UITouch *, NSNumber *> *_owner;   // touch → 'K'<<8|键位 或 'J'（摇杆）
    UITouch *_joy; CGPoint _joyBase, _joyNow;    // 摇杆触摸与底环圆心/当前指位
    CAShapeLayer *_key[B_N], *_pie[6];
    CATextLayer *_lab[B_N];
    CAShapeLayer *_joyRing, *_joyKnob;
    float _cdFrac[6];
    uint64_t _held;                              // 当前按住的键位图（亮态）
}
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }
- (CGPoint)keyCenter:(int)b {
    CGRect r = self.bounds; CGFloat u = self.u;
    CGPoint atk = CGPointMake(r.size.width - K_ATK_DX * u, r.size.height - K_ATK_DY * u);
    if (b == B_A) return atk;
    if (b == B_R) return CGPointMake(r.size.width - K_POT_DX * u, r.size.height - K_POT_DY * u);
    if (b == B_ZL || b == B_PLUS || b == B_MINUS) {
        int i = b == B_PLUS ? 0 : b == B_MINUS ? 1 : 2;   // 自右向左：包/单/城
        return CGPointMake(r.size.width - (K_SYS_DX0 + i * K_SYS_STEP) * u, K_SYS_DY * u + self.safeAreaInsets.top);
    }
    for (int i = 0; i < 5; i++) if (K_ARC_KEY[i] == b) {
        CGFloat a = K_ARC_DEG[i] * M_PI / 180;
        return CGPointMake(atk.x + K_ARC_R * u * cos(a), atk.y - K_ARC_R * u * sin(a));
    }
    return atk;
}
- (CGFloat)keyR:(int)b {
    CGFloat u = self.u;
    return b == B_A ? K_ATK_R * u : b == B_R ? K_POT_R * u : (b == B_ZL || b == B_PLUS || b == B_MINUS) ? K_SYS_R * u : K_ARC_R_KEY * u;
}
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        _owner = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            k_idle = [UIColor colorWithWhite:0.05 alpha:0.55]; k_on = [UIColor colorWithWhite:0.24 alpha:0.85];
            k_line = [UIColor colorWithWhite:0.62 alpha:0.5]; k_text = [UIColor colorWithWhite:0.96 alpha:1];
        });
        _joyRing = mkShape(self.layer); _joyRing.fillColor = UIColor.clearColor.CGColor; _joyRing.hidden = YES;
        _joyKnob = mkShape(self.layer); _joyKnob.hidden = YES;
        static NSString *const names[B_N] = {@"攻", @"6", @"2", @"3", nil, nil, @"5", @"药", @"城", @"4", @"包", @"单"};
        // 弧键标签 = 槽序数字（图标管线接通后换贴图）：X=2 Y=3 ZR=4 L=5 B=6
        for (int b = 0; b < B_N; b++) {
            if (!(b == B_A || b == B_R || b == B_ZL || b == B_PLUS || b == B_MINUS || b == B_X || b == B_Y || b == B_ZR || b == B_L || b == B_B)) continue;
            _key[b] = mkShape(self.layer);
            if (names[b]) _lab[b] = mkLabel(_key[b], names[b]);
        }
        for (int i = 0; i < 6; i++) {   // 冷却扇形：键 layer 内、标签之下
            _pie[i] = [CAShapeLayer layer];
            _pie[i].fillColor = [[UIColor colorWithWhite:0 alpha:0.55] CGColor];
            _pie[i].strokeColor = nil; _pie[i].lineWidth = 0; _pie[i].hidden = YES;
            int b = K_CD_KEY[i];
            if (_lab[b]) [_key[b] insertSublayer:_pie[i] below:_lab[b]]; else [_key[b] addSublayer:_pie[i]];
            _cdFrac[i] = -1;
        }
        // 进游戏门控：游戏 HUD 根槽激活才显示（启动器/加载/过场无按键）
        self.hidden = YES;
        __weak typeof(self) wself = self;
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            __typeof__(self) s = wself;
            if (!s) { [t invalidate]; return; }
            [s syncVisible];
        }];
        [self layoutOnce];
        NSLog(@"[dm] D3 触控面就绪（动态摇杆 + 技能簇 + 系统排；进游戏后显示）");
    }
    return self;
}
- (void)syncVisible {   // 显隐 = 游戏态 ∧ 无物理手柄
    BOOL show = dm_ingame() && !g_phys;
    if (!show && !self.hidden) { [self resetTouches]; self.hidden = YES; }
    else if (show && self.hidden) self.hidden = NO;
}
- (void)layoutOnce { [self setNeedsLayout]; [self layoutIfNeeded]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) {
        if (!_key[b]) continue;
        CGPoint c = [self keyCenter:b]; CGFloat r = [self keyR:b];
        CGPathRef p = circleAt(c, r); _key[b].path = p; _key[b].shadowPath = p; CGPathRelease(p);
        if (_lab[b]) {
            CGFloat fs = b == B_A ? 22 * u : (b == B_R || b == B_ZL || b == B_PLUS || b == B_MINUS) ? 14 * u : 16 * u;
            _lab[b].fontSize = fs;   // 只设 fontSize：CATextLayer 默认系统字体（font 属性要 CTFontRef 桥接，CI 教训）
            _lab[b].frame = CGRectMake(c.x - fs * 1.6, c.y - fs * 0.75, fs * 3.2, fs * 1.5);
        }
        _key[b].contentsScale = self.window.screen.scale ?: self.contentScaleFactor;
        if (_lab[b]) _lab[b].contentsScale = _key[b].contentsScale;
    }
    for (int i = 0; i < 5; i++) {   // 弧键槽序数字（2-6）
        int b = K_ARC_KEY[i];
        if (_lab[b]) _lab[b].string = [NSString stringWithFormat:@"%d", i + 2];
    }
    CGFloat jr = K_JOY_R * u, kr = K_JOY_KNOB * u;
    CGPathRef rp = circleAt(CGPointMake(jr, jr), jr); _joyRing.path = rp; CGPathRelease(rp);
    _joyRing.bounds = CGRectMake(0, 0, 2 * jr, 2 * jr);
    CGPathRef kp = circleAt(CGPointMake(kr, kr), kr); _joyKnob.path = kp; _joyKnob.shadowPath = kp; CGPathRelease(kp);
    _joyKnob.bounds = CGRectMake(0, 0, 2 * kr, 2 * kr);
    [self placeJoy];
    for (int i = 0; i < 6; i++) [self drawPie:i];
    [CATransaction commit];
}
- (void)placeJoy {   // 底环定位到落指点；旋钮按当前指位夹在环内
    CGFloat u = self.u, R = K_JOY_R * u;
    if (!_joy) { _joyRing.hidden = YES; _joyKnob.hidden = YES; return; }
    _joyRing.hidden = NO; _joyKnob.hidden = NO;
    _joyRing.position = _joyBase;
    CGFloat dx = _joyNow.x - _joyBase.x, dy = _joyNow.y - _joyBase.y, d = hypot(dx, dy);
    if (d > R) { dx *= R / d; dy *= R / d; }
    _joyKnob.position = CGPointMake(_joyBase.x + dx, _joyBase.y + dy);
}
- (void)drawPie:(int)slot {
    int b = K_CD_KEY[slot];
    if (!_key[b]) return;
    float frac = _cdFrac[slot];
    _pie[slot].hidden = frac <= 0;
    CGPathRef p = piePath([self keyCenter:b], [self keyR:b] * 0.96, frac);
    _pie[slot].path = p;
    if (p) CGPathRelease(p);
}
- (int)keyAt:(CGPoint)p {   // 命中测试：最近键且在半径 1.15 倍内（技能簇 + 药水 + 系统排）
    static const int keys[] = {B_A, B_X, B_Y, B_ZR, B_L, B_B, B_R, B_ZL, B_PLUS, B_MINUS};
    int best = -1; CGFloat bestd = 1e9;
    for (int i = 0; i < (int)(sizeof keys / sizeof *keys); i++) {
        int b = keys[i];
        CGFloat d = hypot(p.x - [self keyCenter:b].x, p.y - [self keyCenter:b].y);
        if (d < bestd) { bestd = d; best = b; }
    }
    return (best >= 0 && bestd <= [self keyR:best] * 1.15) ? best : -1;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    CGRect r = self.bounds;
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        int k = [self keyAt:p];
        if (k >= 0) { [_owner setObject:@((uint64_t)'K' << 8 | (uint64_t)k) forKey:t]; continue; }
        if (!_joy && p.x < r.size.width * K_JOY_ZONE_X && p.y > r.size.height * K_JOY_ZONE_Y) {
            _joy = t; _joyBase = p; _joyNow = p;
            [_owner setObject:@((uint64_t)'J' << 8) forKey:t];
            continue;
        }
        // 其余区域：忽略（D3 不读触屏透传；hle_touch 合成保留给未来 UI 直调）
    }
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) if (t == _joy) _joyNow = [t locationInView:self];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts {
    for (UITouch *t in ts) {
        [_owner removeObjectForKey:t];
        if (t == _joy) _joy = nil;
    }
    [self recompute];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts]; }
- (void)resetTouches { [_owner removeAllObjects]; _joy = nil; [self recompute]; }
- (void)recompute {
    uint64_t btn = 0;
    for (UITouch *t in _owner) {   // NSMapTable 快速枚举 = 键（旧代码验证过的模式）
        uint64_t x = [_owner objectForKey:t].unsignedLongLongValue;
        if ((x >> 8) == 'K') btn |= 1ull << (x & 0xff);
    }
    int32_t ax = 0, ay = 0;
    if (_joy) {
        CGFloat u = self.u, R = K_JOY_R * u, dz = R * K_JOY_DEAD;
        CGFloat dx = _joyNow.x - _joyBase.x, dy = _joyNow.y - _joyBase.y, d = hypot(dx, dy);
        if (d > dz) {
            CGFloat m = fmin((d - dz) / (R * K_JOY_FULL - dz), 1) / d;
            ax = (int32_t)lrint(dx * m * 32767); ay = (int32_t)lrint(-dy * m * 32767);   // 上=正（host 约定）
        }
    }
    BOOL ch = btn != _held;
    _held = btn;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = btn; g_touch_lx = ax; g_touch_ly = ay; g_touch_rx = 0; g_touch_ry = 0;
    pthread_mutex_unlock(&g_mu);
    publish();
    [self placeJoy];
    if (ch) [self refreshHeld];
}
- (void)refreshHeld {   // 按下态填充
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) if (_key[b]) {
        BOOL on = (_held >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor;
    }
    [CATransaction commit];
}

// hle 层每帧推 D3 技能冷却（slot 0=攻击 1-5=弧键序；frac∈[0,1] 剩余比例，<0 无冷却）。
// 定义在 @implementation 内：可访问私有 ivar（@end 外访问会报 private，CI 实证）。
void dm_gamepad_skill(int slot, float frac) {
    D3TouchUI *v = g_view;
    if (!v || slot < 0 || slot >= 6) return;
    if (fabsf(v->_cdFrac[slot] - frac) < 0.01f) return;   // 1% 节流
    v->_cdFrac[slot] = frac;
    if ([NSThread isMainThread]) [v drawPie:slot];
    else dispatch_async(dispatch_get_main_queue(), ^{ [v drawPie:slot]; });
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
