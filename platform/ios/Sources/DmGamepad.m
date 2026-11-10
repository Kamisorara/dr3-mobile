// D3 触控操作面 —— 安卓 SemanticControlsView 整体移植（2026-11-10 触控轮，kb/17 §6 规格书）。
// 布局 = DmTouchLayout（安卓 1851×849 设计画布右组：攻击 A r94 + 弧 5 键 r220/键54 + 药水/回城/闪避/拾取 r48）
//        + 顶排（包+/单−/赛，视图锚定，真机已验证位置）+ 动态摇杆（左 40% 下半区，底座随落点、静息归设计位）。
// 键位 = 实证表（kb/07 §7 真机 HUD + 安卓 SkillFeedback.target()）：技能槽0:Y 1:B 2:A 3:X 4:ZL 5:ZR、
//        药水=R1、回城=DPad 右、闪避=探测性 L（真机验证；游戏若无此绑定则无害）。
// 渲染 = 安卓 ControlArt 矢量嵌槽（4 层描边环 + 45° 刻度线 + 按下环 + 摇杆 thumb）+ DmTouchSkin PNG
//        （Gen/skin optional；缺失降级文字标签）。冷却饼 = hle_uistate 10Hz frac（-90° 顺时针、#C9000000）。
// 交互 = 技能键（含攻击）全走瞄准手势（安卓 Route 语义）：按下即绑定键 DOWN（按住即瞄/连发），
//        拖超 slop → 虚拟右摇杆 = 拖动向量（游戏原生右摇杆=世界光标，PowerCursorSetToRightStick 0x9143e0），
//        松手 = 键 UP + 右摇杆清零；一槽一手势、多指并发。拾取钮灰显（token 待下轮 native 派发）。
// | Touch overlay — port of the Android SemanticControlsView: design-canvas right group,
// | verified key bindings, vector sockets + optional PNG skin, drag-aim gestures
// | (binding key held + virtual right stick = drag vector), pie cooldowns.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <math.h>
#include "dm_input.h"
#include "game_profile.h"
#import "DmTouchLayout.h"
#import "DmTouchSkin.h"
#import "DmUiPointer.h"
#import "SeasonPanel.h"

extern CGRect dm_ios_game_frame(void);   // front_ios.m：游戏内容区（黑边/安全区已扣）
static DmUip g_uip;                      // UI 指针触点状态机（安卓 UiPointer C 移植）

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

// 触点归属 tag：('K'|'J'|'S'|'P')<<8 | 参数（'S' 低字节 = 技能槽）
enum { TAG_KEY = 'K', TAG_JOY = 'J', TAG_SKILL = 'S', TAG_PANEL = 'P', TAG_UI = 'U' };   // U = 游戏菜单触点（kb/07 §10）

// 壳内键号：0..15 = Npad 位序（= DmTouchLayout 的 DMKJ_*），16+ 伪键
enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS,
       B_LEFT, B_UP, B_RIGHT, B_DOWN, B_SEASON, B_PICKUP, B_N };
#define DMKJ_N B_N

// 触控 slop：iOS 无系统值可读，取 UIPanGestureRecognizer 默认量级（安卓用系统 touchSlop）
static const CGFloat K_SLOP = 12.0;

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
    NSMapTable<UITouch *, NSNumber *> *_owner;
    // 技能瞄准手势（安卓 Gesture：一槽一手势；键在 DOWN 即按下——按住即瞄/连发）
    struct { UITouch *touch; CGPoint origin, now; BOOL dragged; } _gest[6];
    // 摇杆
    UITouch *_joy; CGPoint _joyBase, _joyNow;
    // 几何
    DmTlCanvas _canvas; BOOL _canvasOk;
    DmTlControl _ctl[10]; int _nctl;
    CGPoint _pos[DMKJ_N]; CGFloat _rad[DMKJ_N]; BOOL _built[DMKJ_N];
    CGPoint _joyIdle;
    // 图层（每键：底填充/外环/白环/内环/刻度/按下环/图标/文字）
    CAShapeLayer *_fill[DMKJ_N], *_ro[DMKJ_N], *_rm[DMKJ_N], *_ri[DMKJ_N], *_tick[DMKJ_N], *_hi[DMKJ_N];
    CATextLayer *_lab[DMKJ_N];
    CALayer *_icon[DMKJ_N];
    CAShapeLayer *_pie[6];
    CAShapeLayer *_joyRing, *_joyKnob;
    float _cdFrac[6];
    uint64_t _held;   // 普通键位图（技能手势键不经此，publish 时并）
}

// ---- 键位映射 ----
+ (int)slotKey:(int)slot { return DM_SKILL_SLOT_KEY(slot); }   // 槽 → 键号（0:Y 1:B 2:A 3:X 4:ZL 5:ZR）

// 布局模型键 → 皮肤图标 key（安卓 ControlSkin.iconKey + 技能通用图）
+ (NSString *)iconKey:(DmTlControl *)c {
    if (c->slot >= 0) return [NSString stringWithFormat:@"skill%d", c->slot + 1];   // 通用图（动态映射下轮接）
    switch (c->button) {
        case B_R: return @"potion"; case B_RIGHT: return @"portal";
        case B_L: return @"evade";  case B_PICKUP: return @"pickup";
        case B_PLUS: return @"inventory"; case B_MINUS: return @"menu";
        default: return nil;
    }
}
+ (NSString *)label:(DmTlControl *)c {
    if (c->slot >= 0) return c->slot == 2 ? @"攻" : [NSString stringWithFormat:@"%d", c->slot + 1];
    switch (c->button) {
        case B_R: return @"药"; case B_RIGHT: return @"城"; case B_L: return @"闪";
        case B_PICKUP: return @"拾"; default: return nil;
    }
}

- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 顶排/字号单位（真机已验证量级）

- (void)applySkillAtlas:(const unsigned char *)rgba w:(int)w h:(int)h {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate((void *)rgba, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return;
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFRelease(ctx);
    if (!img) return;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int i = 0; i < 6; i++) {   // row0 前 6 格 = 技能 1-6（128px/格——网格假设未实证，图集管线仍暂停中）
        int b = [D3TouchUI slotKey:i];   // 槽 i 的键（0:Y 1:B 2:A 3:X 4:ZL 5:ZR）
        if (b < 0 || b >= DMKJ_N || !_built[b] || !_fill[b]) continue;
        CGImageRef tile = CGImageCreateWithImageInRect(img, CGRectMake(i * 128, 0, 128, 128));
        if (!tile) continue;
        if (!_icon[b]) {
            _icon[b] = [CALayer layer];
            _icon[b].contentsGravity = kCAGravityResizeAspect;
            _icon[b].masksToBounds = YES;
            [_fill[b].superlayer insertSublayer:_icon[b] above:_fill[b]];
        }
        CGPoint c = _pos[b]; CGFloat r = _rad[b];
        _icon[b].frame = CGRectMake(c.x - r * 0.82, c.y - r * 0.82, r * 1.64, r * 1.64);
        _icon[b].cornerRadius = r * 0.82;   // 圆形裁切（暗黑不朽观感）
        _icon[b].contents = (__bridge id)tile;
        _icon[b].contentsScale = self.window.screen.scale ?: 2;
        CGImageRelease(tile);
        if (_lab[b]) _lab[b].hidden = YES;
    }
    [CATransaction commit];
    CGImageRelease(img);
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        _owner = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            k_idle = [UIColor colorWithWhite:0.05 alpha:0.55]; k_on = [UIColor colorWithWhite:0.24 alpha:0.85];
            k_line = [UIColor colorWithWhite:0.62 alpha:0.5]; k_text = [UIColor colorWithWhite:0.96 alpha:1];
            k_ring = [UIColor colorWithWhite:1 alpha:0.28];
            k_pie  = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.788];   // #C9000000
        });
        // 进游戏门控：游戏 HUD 根槽激活才显示（启动器/加载/过场无按键）
        self.hidden = YES;
        __weak typeof(self) wself = self;
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            __typeof__(self) s = wself;
            if (!s) { [t invalidate]; return; }
            [s syncVisible];
        }];
        NSLog(@"[dm] D3 触控面（安卓画布右组 + 实证键位 Y/B/A/X/ZL/ZR + 药R/城DPad右）：进游戏后显示");
    }
    return self;
}

- (void)syncVisible {   // 显隐 = 游戏态 ∧ 无物理手柄
    BOOL show = dm_ingame() && !g_phys;
    if (!show && !self.hidden) { [self resetTouches]; self.hidden = YES; }
    else if (show && self.hidden) self.hidden = NO;
}

// ---- 几何 ----
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    UIEdgeInsets safe = self.safeAreaInsets;
    DmTlView v = { safe.left, safe.top, safe.right, safe.bottom, b.size.width, b.size.height, 1 };
    DmTlCanvas c; _canvasOk = dm_tl_canvas(&v, &_canvas);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    // 顶排（现行已验证几何）：r=19，自右向左 包/单/赛，y=150
    {
        CGFloat u = self.u;
        static const int topKeys[3] = {B_PLUS, B_MINUS, B_SEASON};
        static NSString *const topNames[3] = {@"包", @"单", @"赛"};
        static NSString *const topIcons[3] = {@"inventory", @"menu", nil};
        for (int i = 0; i < 3; i++) {
            int k = topKeys[i];
            _pos[k] = CGPointMake(b.size.width - (40 + i * 48) * u, 150 * u + safe.top);
            _rad[k] = 19 * u;
            _built[k] = YES;
            [self buildVisual:k label:topNames[i] icon:topIcons[i]];
        }
    }
    // 右组（安卓设计画布）
    if (_canvasOk) {
        _nctl = dm_tl_default_controls(_ctl, 10);
        for (int i = 0; i < _nctl; i++) {
            DmTlControl *ct = &_ctl[i];
            double x, y; dm_tl_point(&_canvas, ct->x, ct->y, ct->inGroup, &x, &y);
            int k = ct->button;
            if (k < 0 || k >= DMKJ_N) continue;
            _pos[k] = CGPointMake(x, y); _rad[k] = ct->r * _canvas.scale;
            _built[k] = YES;
            [self buildVisual:k label:[D3TouchUI label:ct] icon:[D3TouchUI iconKey:ct]];
        }
        // 摇杆静息位（设计 (left+190, groupTop+620) r123——x 视图左锚、y 右组顶锚，安卓 SCV:1109）
        double jx = v.left + 190 * _canvas.scale, jy = _canvas.groupY + 620 * _canvas.scale;
        _joyIdle = CGPointMake(jx, jy);
        CGFloat jr = 123 * _canvas.scale;
        if (!_joyRing) {
            _joyRing = mkShape(self.layer); _joyRing.fillColor = UIColor.clearColor.CGColor; _joyRing.hidden = YES;
            _joyKnob = mkShape(self.layer); _joyKnob.hidden = YES;
        }
        CGPathRef rp = circleAt(CGPointMake(jr, jr), jr); _joyRing.path = rp; CGPathRelease(rp);
        _joyRing.bounds = CGRectMake(0, 0, 2 * jr, 2 * jr);
        CGFloat kr = 26 * _canvas.scale;
        CGPathRef kp = circleAt(CGPointMake(kr, kr), kr); _joyKnob.path = kp; _joyKnob.shadowPath = kp; CGPathRelease(kp);
        _joyKnob.bounds = CGRectMake(0, 0, 2 * kr, 2 * kr);
        [self placeJoy];
    }
    for (int i = 0; i < 6; i++) [self drawPie:i];
    [CATransaction commit];
}

// 每键视觉：底填充 + 外环 + 白环 + 内环 + 45° 刻度线 + 按下环 + 图标/文字（安卓 ControlArt.socket 移植）
- (void)buildVisual:(int)k label:(NSString *)text icon:(NSString *)iconKey {
    CGPoint c = _pos[k]; CGFloat r = _rad[k];
    if (!_fill[k]) {
        _fill[k] = mkShape(self.layer);
        _ro[k] = mkShape(self.layer); _ro[k].fillColor = nil;
        _rm[k] = mkShape(self.layer); _rm[k].fillColor = nil; _rm[k].strokeColor = k_ring.CGColor;
        _ri[k] = mkShape(self.layer); _ri[k].fillColor = nil;
        _tick[k] = mkShape(self.layer); _tick[k].fillColor = nil; _tick[k].strokeColor = k_ring.CGColor;
        _hi[k] = mkShape(self.layer); _hi[k].fillColor = nil; _hi[k].hidden = YES;
        _hi[k].strokeColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
    }
    CGPathRef p = circleAt(c, r); _fill[k].path = p; _fill[k].shadowPath = p; CGPathRelease(p);
    CGFloat scale = self.window.screen.scale ?: 2;
    _ro[k].lineWidth = fmax(1, 0.016 * r); _rm[k].lineWidth = fmax(1, 0.03 * r);
    _ri[k].lineWidth = fmax(1, 0.012 * r); _hi[k].lineWidth = fmax(1, 0.025 * r);
    CGPathRef po = circleAt(c, r * 0.982); _ro[k].path = po; CGPathRelease(po);
    CGPathRef pm = circleAt(c, r * 0.956); _rm[k].path = pm; CGPathRelease(pm);
    CGPathRef pi_ = circleAt(c, r * 0.929); _ri[k].path = pi_; CGPathRelease(pi_);
    CGPathRef ph = circleAt(c, r * 0.925); _hi[k].path = ph; CGPathRelease(ph);
    CGMutablePathRef tp = CGPathCreateMutable();
    for (int q = 0; q < 4; q++) {   // 45°/135°/225°/315° 刻度线（r0.944→0.97）
        CGFloat a = (q * 0.5 + 0.25) * (CGFloat)M_PI;
        CGPathMoveToPoint(tp, NULL, c.x + r * 0.944 * cos(a), c.y + r * 0.944 * sin(a));
        CGPathAddLineToPoint(tp, NULL, c.x + r * 0.97 * cos(a), c.y + r * 0.97 * sin(a));
    }
    _tick[k].path = tp; _tick[k].lineWidth = fmax(1, 0.008 * r); CGPathRelease(tp);
    _fill[k].contentsScale = _ro[k].contentsScale = _rm[k].contentsScale = _ri[k].contentsScale = scale;
    _tick[k].contentsScale = _hi[k].contentsScale = scale;
    if (k == B_PICKUP) _fill[k].opacity = 0.45f;   // 灰显：token 无来源（下轮 native 派发）
    UIImage *img = iconKey ? [DmTouchSkin.shared image:iconKey] : nil;
    if (img) {
        if (!_icon[k]) { _icon[k] = [CALayer layer]; _icon[k].contentsGravity = kCAGravityResizeAspect; _icon[k].masksToBounds = YES; [_fill[k].superlayer insertSublayer:_icon[k] above:_fill[k]]; }
        _icon[k].frame = CGRectMake(c.x - r * 0.82, c.y - r * 0.82, r * 1.64, r * 1.64);
        _icon[k].cornerRadius = r * 0.82;
        _icon[k].contents = (__bridge id)img.CGImage;
        _icon[k].contentsScale = scale;
        _icon[k].hidden = NO;
        if (_lab[k]) _lab[k].hidden = YES;
    } else {
        if (_icon[k]) _icon[k].hidden = YES;
        if (text && !_lab[k]) _lab[k] = mkLabel(_fill[k], text);
        if (_lab[k]) {
            CGFloat fs = k == B_A ? 22 * self.u : 14 * self.u;
            _lab[k].fontSize = fs;   // 只设 fontSize（CATextLayer.font 要 CTFontRef 桥接，CI 教训）
            _lab[k].frame = CGRectMake(c.x - fs * 1.6, c.y - fs * 0.75, fs * 3.2, fs * 1.5);
            _lab[k].contentsScale = scale;
            _lab[k].hidden = NO;
        }
    }
}

- (void)placeJoy {   // 底座恒显（安卓语义）：静息归设计位，落指跟随；旋钮夹在环内
    if (!_joyRing || !_canvasOk) return;
    CGPoint base = _joy ? _joyBase : _joyIdle;
    _joyRing.hidden = NO; _joyKnob.hidden = NO;
    _joyRing.position = base;
    CGFloat R = 123 * _canvas.scale;
    CGFloat dx = _joy ? _joyNow.x - base.x : 0, dy = _joy ? _joyNow.y - base.y : 0, d = hypot(dx, dy);
    if (d > R) { dx *= R / d; dy *= R / d; }
    _joyKnob.position = CGPointMake(base.x + dx, base.y + dy);
}

- (void)drawPie:(int)slot {
    int b = [D3TouchUI slotKey:slot];
    if (b < 0 || b >= DMKJ_N || !_built[b] || !_fill[b]) return;
    if (!_pie[slot]) {
        _pie[slot] = [CAShapeLayer layer];
        _pie[slot].fillColor = k_pie.CGColor; _pie[slot].strokeColor = nil; _pie[slot].lineWidth = 0; _pie[slot].hidden = YES;
        [_fill[b].superlayer insertSublayer:_pie[slot] above:_fill[b]];
    }
    float frac = _cdFrac[slot];
    _pie[slot].hidden = frac <= 0;
    CGPathRef p = piePath(_pos[b], _rad[b] * 0.86, frac);   // 安卓：r=0.86×halfW，#C9000000
    _pie[slot].path = p;
    if (p) CGPathRelease(p);
}

// ---- 命中 ----
- (int)keyAt:(CGPoint)p {   // 最近键 1.15 倍容差：顶排 + 右组；拾取钮灰显不响应
    int best = -1; CGFloat bestd = 1e9;
    for (int k = 0; k < DMKJ_N; k++) {
        if (!_built[k] || k == B_PICKUP) continue;
        CGFloat d = hypot(p.x - _pos[k].x, p.y - _pos[k].y);
        if (d < bestd) { bestd = d; best = k; }
    }
    return (best >= 0 && bestd <= _rad[best] * 1.15) ? best : -1;
}

- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self];
        int k = [self keyAt:p];
        if (k == B_SEASON) { [_owner setObject:@((uint64_t)TAG_PANEL << 8) forKey:t]; [SeasonPanel presentInView:self]; continue; }
        if (k >= 0 && k != B_PICKUP) {
            int slot = -1;
            for (int i = 0; i < _nctl; i++) if (_ctl[i].button == k && _ctl[i].slot >= 0) { slot = _ctl[i].slot; break; }
            if (slot >= 0 && !_gest[slot].touch) {   // 技能键（含攻击）= 瞄准手势：一槽一手势
                _gest[slot].touch = t; _gest[slot].origin = p; _gest[slot].now = p; _gest[slot].dragged = NO;
                [_owner setObject:@(((uint64_t)TAG_SKILL << 8) | (uint64_t)slot) forKey:t];
                continue;
            }
            if (slot >= 0) continue;   // 同槽已有手势：忽略第二个手指（安卓 begin 语义）
            [_owner setObject:@(((uint64_t)TAG_KEY << 8) | (uint64_t)k) forKey:t];
            continue;
        }
        if (!_joy) {
            DmTlView v = { self.safeAreaInsets.left, self.safeAreaInsets.top, self.safeAreaInsets.right,
                           self.safeAreaInsets.bottom, self.bounds.size.width, self.bounds.size.height, 1 };
            if (dm_tl_stick_zone(&v, p.x, p.y)) {
                _joy = t; _joyBase = p; _joyNow = p;
                [_owner setObject:@((uint64_t)TAG_JOY << 8) forKey:t];
                continue;
            }
        }
        [_owner setObject:@((uint64_t)TAG_UI << 8) forKey:t];   // 未命中控件 = 游戏菜单触点（kb/07 §10 UI 指针域）
    }
    [self uiPublishAll:NO];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        NSNumber *tag = [_owner objectForKey:t];
        if (!tag) continue;
        uint64_t x = tag.unsignedLongLongValue;
        CGPoint p = [t locationInView:self];
        if ((x >> 8) == TAG_JOY && t == _joy) _joyNow = p;
        else if ((x >> 8) == TAG_SKILL) {
            int slot = (int)(x & 0xff);
            if (slot >= 0 && slot < 6 && _gest[slot].touch == t) {
                _gest[slot].now = p;
                if (hypot(p.x - _gest[slot].origin.x, p.y - _gest[slot].origin.y) > K_SLOP) _gest[slot].dragged = YES;
            }
        }
    }
    [self uiPublishAll:NO];
    [self recompute];
}
// UI 指针发布：扫 _owner 里的 TAG_UI 触点集 → DmUiPointer 状态机 → dm_uipointer_set 入宿主队列。
// 坐标基准 = dm_ios_game_frame（游戏内容区，黑边/安全区已扣；空则回退 self.bounds）。
- (void)uiPublishAll:(BOOL)cancelled {
    int ids[16]; float xs[16], ys[16]; int n = 0;
    CGRect f = dm_ios_game_frame();
    if (f.size.width <= 0 || f.size.height <= 0) f = self.bounds;
    for (UITouch *t in _owner) {
        NSNumber *tag = [_owner objectForKey:t];
        if (!tag || (tag.unsignedLongLongValue >> 8) != TAG_UI || n >= 16) continue;
        CGPoint p = [t locationInView:self];
        ids[n] = (int)(uintptr_t)t;
        xs[n] = (float)((p.x - f.origin.x) / f.size.width);
        ys[n] = (float)((p.y - f.origin.y) / f.size.height);
        n++;
    }
    long long ms = (long long)(CFAbsoluteTimeGetCurrent() * 1000.0), oms = 0;
    DmUipEvent ev;
    if (dm_uip_publish(&g_uip, ids, xs, ys, n, cancelled, ms, &oms, &ev))
        dm_uipointer_set(ev.phase, ev.x, ev.y, ev.bx, ev.by, oms, ev.paired);
}
- (void)endTouches:(NSSet<UITouch *> *)ts {
    for (UITouch *t in ts) {
        NSNumber *tag = [_owner objectForKey:t];
        [_owner removeObjectForKey:t];
        if (!tag) continue;
        uint64_t x = tag.unsignedLongLongValue;
        if ((x >> 8) == TAG_JOY && t == _joy) _joy = nil;
        else if ((x >> 8) == TAG_SKILL) {
            int slot = (int)(x & 0xff);
            if (slot >= 0 && slot < 6 && _gest[slot].touch == t)
                _gest[slot].touch = NULL, _gest[slot].dragged = NO;
        }
    }
    [self uiPublishAll:NO];
    [self recompute];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    [self endTouches:ts];
    [self uiPublishAll:YES];   // 系统取消：UI 指针发相位 3（安卓 ACTION_CANCEL 同款）
}
- (void)resetTouches {
    [_owner removeAllObjects]; _joy = nil;
    dm_uip_init(&g_uip);
    for (int i = 0; i < 6; i++) { _gest[i].touch = NULL; _gest[i].dragged = NO; }
    [self recompute];
}

- (void)recompute {
    uint64_t btn = 0;
    for (UITouch *t in _owner) {
        uint64_t x = [_owner objectForKey:t].unsignedLongLongValue;
        if ((x >> 8) == TAG_KEY) btn |= 1ull << (x & 0xff);
    }
    for (int slot = 0; slot < 6; slot++)   // 技能手势 = 绑定键保持按下（按住即瞄/连发）
        if (_gest[slot].touch) btn |= 1ull << [D3TouchUI slotKey:slot];
    int32_t ax = 0, ay = 0, brx = 0, bry = 0;
    if (_joy) {
        CGFloat R = _canvasOk ? 123 * _canvas.scale : 62 * self.u, dz = R * 0.12;
        CGFloat dx = _joyNow.x - _joyBase.x, dy = _joyNow.y - _joyBase.y, d = hypot(dx, dy);
        if (d > dz) {
            CGFloat m = fmin((d - dz) / (R * 0.72 - dz), 1) / d;
            ax = (int32_t)lrint(dx * m * 32767); ay = (int32_t)lrint(-dy * m * 32767);   // 上=正（host 约定）
        }
    }
    for (int slot = 0; slot < 6; slot++) {   // 拖动瞄准：第一拖动手势的方向 → 虚拟右摇杆（游戏原生右摇杆=世界光标）
        if (!_gest[slot].dragged) continue;
        CGFloat dx = _gest[slot].now.x - _gest[slot].origin.x, dy = _gest[slot].now.y - _gest[slot].origin.y;
        CGFloat d = hypot(dx, dy);
        if (d > K_SLOP) { brx = (int32_t)lrint(dx / d * 32767); bry = (int32_t)lrint(-dy / d * 32767); }
        break;
    }
    BOOL ch = btn != _held;
    _held = btn;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = btn; g_touch_lx = ax; g_touch_ly = ay; g_touch_rx = brx; g_touch_ry = bry;
    pthread_mutex_unlock(&g_mu);
    publish();
    [self placeJoy];
    if (ch) [self refreshHeld];
}
- (void)refreshHeld {   // 按下态：底填充换亮色 + 按下环
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int k = 0; k < DMKJ_N; k++) {
        if (!_built[k] || !_fill[k]) continue;
        BOOL on = (_held >> k) & 1;
        _fill[k].fillColor = (on ? k_on : k_idle).CGColor;
        _hi[k].hidden = !on;
    }
    [CATransaction commit];
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

// nvn_mtl 推技能图标图集（图集管线仍暂停中；接口保留，槽→键映射已换实证表）。
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
