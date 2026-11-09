// UIKit touch controls publish separately from the shared physical backend.
//   Two layouts; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D") switches them, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_FULL).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick (inward of and below the diamond, a smaller ring)
//     and L3 / R3 (small round keys in the top row, inward of ZL / ZR). Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the two sticks has the smallest distance / grab radius (the left stick's grab circle borders the D-pad).
//   D2R's generic thin skill sockets and soft matte stick art are cached at geometry changes; presses swap small layer contents and movement only changes the knob position. No game-specific skill glyphs or full-screen redraw.
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller).
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm_input.h"
#include "game_profile.h"
#include "DmTouchControlArt.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS,
       B_LEFT, B_UP, B_RIGHT, B_DOWN,   // 12-15 = NpadButton 十字键位序：直接透传（此前错位成摇杆伪键）
       B_BAG, B_MENU,                   // 16+ 纯虚拟键：fill() 的 &0xffff 掩掉，recompute 里仍显式剔除
       B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME };   // which control a touch holds; C_GAME = game-screen passthrough (hle_touch)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
void dm_gamepad_start(void (*on_present)(int present));
void dm_physical_gamepad_reset(void);
// 游戏区触摸透传（hle_touch.c 合成 nn::hid::TouchScreenState，游戏 main 0x1b65260 原生读取）：
// 坐标 = 出图画面归一化 [0,1)，原点左上；frame 由 front_ios 的 dm_ios_game_frame 提供（letterbox/适配几何都在里面）。
// | Game-area touch passthrough: coordinates normalized to the output frame, origin top left.
typedef struct { unsigned id; float x, y; } dm_touch;
extern void dm_touch_set(const dm_touch *t, int n);
extern CGRect dm_ios_game_frame(void);
extern void dm_hudmove_set_controller(int present);   // 物理手柄 presence → HUD 移位还原（hle_hudmove.c）| physical pad presence → HUD restore
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 94,                    // diamond/stick centre from the bottom. 82→94（2026-11-09）：摇杆满拨下缘 82-77=5pt 贴屏边，向下推手指易滑出屏 → 触摸结束人物停（「往下划不动」根因）；94 给 17pt 缓冲
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_BAR_X = 60, K_BAR_Y = 195, K_BAR_DX = 46, K_BAR_R = 22,      // D3 图标栏：✕/单/包/城 自右向左等距（城市键离最远，贴 mockup）
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad / right stick centre from the outer edge and the bottom (inward of and below the left stick / the diamond, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60, K_RKNOB_R = 24,                // right stick: ring and knob radius
    K_CLICK_X = 102, K_CLICK_R = 17,                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
    K_ARC_R = 100;                                  // D3 技能弧半径（主攻心到弧键心；角度组避让右上图标栏）
static const CGFloat K_ARC_DEG[5] = {110, 138, 166, 194, 218};   // 技能 2-6 弧位（数学角；UIKit y 向下 → (cos, −sin)）。218° 尾键随 K_PAD_Y 上移收 4° 防下缘出屏
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_BAG, B_MENU, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 1 = 3D, 0 = 2D

@interface DmGamepad : UIView
@end
static __weak DmGamepad *g_view;

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    NSMutableArray<UITouch *> *_gtouch;            // 游戏区透传触摸（有序，index = finger_id）| ordered game-area passthrough touches
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CALayer *_socket[4];
    CAShapeLayer *_ring[2], *_knob[2];
    UIImage *_socketArt[2], *_baseArt[2][2], *_thumbArt[2][2];
    CGFloat _artUnit, _artScale;
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    BOOL _sticksShown;                             // a stick was held at the last refresh
    BOOL _menuMode;                                // 菜单态：摇杆+技能环隐藏（包/单/±打开，✕关闭）；菜单内点击→方向注入
    BOOL _menuPending;                             // 菜单态切换已排队（防重入）
    uint64_t _pulse;                               // 菜单点击单发脉冲位（130ms 自动抬）| one-shot key pulses for menu clicks
    BOOL _full;                                    // the 3D layout is current
    BOOL _d3;                                      // D3 专用布局：技能环 + 语义标签（键=真实键，只改几何/标签）
    CAShapeLayer *_skillCd[6];                     // D3 技能冷却扇形遮罩（slot 0=主攻 1-5=弧键；数据由 hle 层每帧推）
    float _cdFrac[6];                              // 最近一次推送的冷却比例（-1=无冷却），重画节流用
}

static UIColor *k_idle, *k_on, *k_line, *k_text, *k_textOn;
static UIImage *k_socketTexture;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = parent.contentsScale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) {   // 仅 3D 布局显示的键（显式列举：包/单等尾部枚举不受影响）
    return b == B_LS || b == B_RS || b == B_LEFT || b == B_UP || b == B_RIGHT || b == B_DOWN;
}
static CGPathRef piePath(CGPoint c, CGFloat r, float frac) {   // 冷却遮罩扇形：正上起顺时针扫剩余比例
    if (frac <= 0) return NULL;
    if (frac > 1) frac = 1;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, c.x, c.y);
    CGPathAddArc(p, NULL, c.x, c.y, r, -M_PI_2, -M_PI_2 + 2 * (CGFloat)M_PI * frac, NO);
    CGPathCloseSubpath(p);
    return p;
}

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        _gtouch = [NSMutableArray array];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:0.045 alpha:0.64]; k_on = [UIColor colorWithWhite:0.19 alpha:0.86]; k_line = [UIColor colorWithWhite:0.62 alpha:0.52];
            k_text = [UIColor colorWithWhite:0.95 alpha:1]; k_textOn = UIColor.whiteColor;
            k_socketTexture = [UIImage imageNamed:@"dm_mobile_socket"];
            if(!k_socketTexture) {
                NSString *path=[NSBundle.mainBundle pathForResource:@"dm_mobile_socket" ofType:@"png" inDirectory:@"ControlArt"];
                if(path)k_socketTexture=[UIImage imageWithContentsOfFile:path];
            }
            if(!k_socketTexture)NSLog(@"[dm] touch art socket missing; using vector socket fallback");
        });
        for (int i = 0; i < 2; i++) {
            _ring[i] = shape(self.layer); _ring[i].fillColor = UIColor.clearColor.CGColor; _ring[i].strokeColor = nil; _ring[i].shadowOpacity = 0;
            _knob[i] = shape(self.layer);
            _knob[i].fillColor = UIColor.clearColor.CGColor; _knob[i].strokeColor = nil;
        }
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−", @"←", @"↑", @"→", @"↓", @"包", @"单"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(self.layer);
            if(b<=B_Y) {
                _key[b].fillColor=UIColor.clearColor.CGColor;_key[b].strokeColor=nil;
                _socket[b]=[CALayer layer];[_key[b] addSublayer:_socket[b]];
            }
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(self.layer); _swapLabel = label(_swap, @"");
        static const int skillKeyOf[6] = {B_A, B_X, B_Y, B_R, B_B, B_L};   // D3 技能槽→键（0=主攻 1-5=弧）
        for (int i = 0; i < 6; i++) {   // 冷却扇形遮罩：挂在键 layer 内、标签之下（盖 socket 不盖编号）
            _skillCd[i] = [CAShapeLayer layer];
            _skillCd[i].fillColor = [[UIColor colorWithWhite:0 alpha:0.55] CGColor];
            _skillCd[i].strokeColor = nil; _skillCd[i].lineWidth = 0; _skillCd[i].hidden = YES;
            [_key[skillKeyOf[i]] insertSublayer:_skillCd[i] below:_label[skillKeyOf[i]]];
            _cdFrac[i] = -1;
        }
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        // 三态布局：0 = 2D、1 = 3D、2 = D3（旧布尔 0/1 迁移）；D3 为触控模式默认意图见 setD3
        int mode = saved ? saved.intValue : (DM_GAME_PAD_FULL ? 1 : 0);
        _d3 = mode == 2; _full = mode == 1;
        [self applyLayout];
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _d3 ? (b == B_LS || b == B_RS ||
        b == B_LEFT || b == B_UP || b == B_RIGHT || b == B_DOWN ||
        b == B_PLUS || b == B_MINUS) : (fullOnly(b) && !_full);   // D3：±本体隐藏（B_L=Skill6 上弧；包/单 pill = 同功能的语义入口）
    _ring[1].hidden = _knob[1].hidden = _d3 || !_full;
    if (_d3) _label[B_B].string = _menuMode ? @"✕" : @"5";   // B_B 双语义：游戏态=Skill5，菜单态=✕ 取消
    if (_menuMode) {   // 菜单态：摇杆+技能弧+药水全隐，只留图标栏（✕/单/包/城 = 菜单操作键）
        for (int b = 0; b < B_N; b++) _key[b].hidden = !(b == B_B || b == B_BAG || b == B_MENU || b == B_ZR);
        _ring[0].hidden = _knob[0].hidden = YES;
        _swap.hidden = _swapLabel.hidden = YES;
    } else {
        _swap.hidden = _swapLabel.hidden = NO;
    }
    for (int i = 0; i < 6; i++) _skillCd[i].hidden = !(_d3 && !_menuMode);   // 冷却遮罩随技能弧
    _swapLabel.string = _d3 ? @"D3" : _full ? @"3D" : @"2D";
    [CATransaction commit];
}
- (void)setMenuMode:(BOOL)m {   // 菜单态切换：清空全部按住的触摸（防止键卡住）后重排可见性
    if (m == _menuMode) return;
    [self reset];
    _menuMode = m;
    [self applyLayout]; [self setNeedsLayout];
}
- (void)updateSkillCd:(int)slot {   // 冷却遮罩重画（数据已入 _cdFrac；主线程）
    static const int skillKeyOf[6] = {B_A, B_X, B_Y, B_R, B_B, B_L};
    if (!_d3 || slot < 0 || slot >= 6) return;
    int b = skillKeyOf[slot];
    float frac = _cdFrac[slot];
    _skillCd[slot].hidden = frac <= 0 || _menuMode;
    CGPathRef p = piePath([self facePos:b], [self faceKeyR:b] * 0.97, frac);
    _skillCd[slot].path = p;   // frac<=0 → NULL = 清空
    if (p) CGPathRelease(p);
}
- (void)pulse:(int)b {   // 菜单点击单发脉冲：按下约 130ms 后自动抬起（点击→方向→注入，§15 路线 A）
    pthread_mutex_lock(&g_mu); _pulse |= 1ull << b; pthread_mutex_unlock(&g_mu);
    [self recompute];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 130 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        pthread_mutex_lock(&g_mu); _pulse &= ~(1ull << b); pthread_mutex_unlock(&g_mu);
        [self recompute];
    });
}
- (void)setFull:(BOOL)full {   // switch layouts: release every touch first (no key stays held), save, lay out again
    if (full == _full && !_d3) return;
    [self reset];
    _full = full; _d3 = NO;
    [NSUserDefaults.standardUserDefaults setObject:@(full ? 1 : 0) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}
- (void)setD3:(BOOL)d3 {   // D3 专用布局（触控模式默认）：真实键重排为技能环 + 语义标签
    if (d3 == _d3) return;
    [self reset];
    _d3 = d3; if (d3) _full = NO;
    [NSUserDefaults.standardUserDefaults setObject:@(d3 ? 2 : 0) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGPoint)facePos:(int)b {
    if (_d3) {   // 暗黑不朽式 6 技能：主攻大键贴右下角，技能 2-6 弧形绕主攻（左上扇形，避让右上图标栏），✕ 菜单态回图标栏
        CGPoint c = self.faceCenter; CGFloat u = self.u;   // faceCenter = 右下角骨架原点 (W-81u, H-82u)
        CGPoint hero = CGPointMake(c.x - 37 * u, c.y + 6 * u);
        if (b == B_A) return hero;                                      // Skill1 主攻（大键）
        if (b == B_B && _menuMode) return [self d3BarPos:B_B];          // 菜单态 ✕ 回图标栏最右
        static const int arcKey[5] = {B_X, B_Y, B_R, B_B, B_L};         // Skill2-6（B_B 游戏态=Skill5）
        for (int i = 0; i < 5; i++) if (arcKey[i] == b) {
            CGFloat a = K_ARC_DEG[i] * M_PI / 180;
            return CGPointMake(hero.x + K_ARC_R * u * cos(a), hero.y - K_ARC_R * u * sin(a));
        }
        return hero;
    }
    CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); }
}
- (CGFloat)faceKeyR:(int)b {   // 键面半径（D3：主攻大键，弧键次之；菜单态 ✕ 用图标栏半径）
    if (_d3) { CGFloat u = self.u; return b == B_A ? 48 * u : (b == B_B && _menuMode ? K_BAR_R * u : 26 * u); }
    return self.faceR;
}
- (CGPoint)stickHome:(int)i { CGRect s = self.corner; CGFloat u = self.u;
    return i ? side(s, 1, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u) : side(s, 0, K_STICK_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : K_STICK_R) * self.u; }
- (CGPoint)dpadCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u); }
- (CGFloat)dpadR { return K_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)d3BarPos:(int)b {   // D3 右上图标栏：✕(B_B)/单(B_MENU)/包(B_BAG)/城(B_ZR) 自右向左
    CGFloat u = self.u; int slot = b == B_B ? 0 : b == B_MENU ? 1 : b == B_BAG ? 2 : 3;
    return CGPointMake(self.bounds.size.width - (K_BAR_X + slot * K_BAR_DX) * u, K_BAR_Y * u);
}
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    if (_d3 && b == B_ZR) return [self d3BarPos:B_ZR];   // D3：城在图标栏（不再是顶部泪滴）
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    if (_d3 && (b == B_BAG || b == B_MENU)) {   // D3：包/单并入右上图标栏（圆键；返回外接方供命中与圆角矩形绘制——正方形圆角=圆）
        CGPoint c = [self d3BarPos:b]; return CGRectMake(c.x - K_BAR_R * u, c.y - K_BAR_R * u, 2 * K_BAR_R * u, 2 * K_BAR_R * u); }
    // − 在中线左、+ 在右；背包 / 菜单快捷键再往外一档（D3：包 = Y、菜单 = + 的重复入口，游戏内改键后语义跟随真实键）
    CGFloat off = b == B_PLUS ? K_PILL_DX : b == B_MINUS ? -K_PILL_DX
                : b == B_MENU ? K_PILL_DX * 2 + 10 : b == B_BAG ? -(K_PILL_DX * 2 + 10) : 0;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + off * u, CGRectGetMinY(s) + K_PILL_Y * u);
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        if (_d3 && (b == B_PLUS || b == B_MINUS)) continue;   // D3：±本体已隐藏（功能=包/单图标键）
        if (_d3 && (b == B_R || b == B_L || b == B_B)) continue;   // D3：弧键组走 faceAt（滑动换键）
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= (b == B_ZR && _d3 ? K_BAR_R : [self dropR:b]) * 1.2
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -(b == B_BAG || b == B_MENU ? (_d3 ? 2 : 8) : 8) * u, -(b == B_BAG || b == B_MENU ? (_d3 ? 2 : 8) : 8) * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0;
    if (_d3) {   // 技能弧 6 键：主攻大半径，弧键小半径；只报一个最近的（弧没有"两键之间"语义）
        static const int skillKeys[6] = {B_A, B_X, B_Y, B_R, B_B, B_L};
        int best = -1; CGFloat bestd = 1e9;
        for (int i = 0; i < 6; i++) { CGFloat d = dist(p, [self facePos:skillKeys[i]]); if (d < bestd) { bestd = d; best = skillKeys[i]; } }
        CGFloat u = self.u;
        if (best >= 0 && bestd <= (best == B_A ? 50 * u : 28 * u)) m |= 1ull << best;
        return m;
    }
    CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the ring centre (clamped to the ring)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickHome:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)syncGameTouches {   // 游戏区触摸全集 → dm_touch_set（hle_touch 合成 TouchScreenState）；index 即 finger_id，抬起前稳定
    NSMutableArray<UITouch *> *gt = _gtouch;
    dm_touch arr[16]; int n = 0;
    CGRect f = gt.count ? dm_ios_game_frame() : CGRectZero;
    for (UITouch *t in gt) {
        if (n >= 16) break;
        CGPoint p = [t locationInView:self];
        arr[n].id = (unsigned)n;
        arr[n].x = f.size.width > 0 ? (float)((p.x - f.origin.x) / f.size.width) : 0;
        arr[n].y = f.size.height > 0 ? (float)((p.y - f.origin.y) / f.size.height) : 0;
        n++;
    }
    dm_touch_set(arr, n);
}
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    // 背包 / 菜单快捷键：包 = +（D3 的 + 打开背包/物品面板）、单 = −（系统菜单）——真机实测定标。
    // B_BAG/B_MENU 自有位（16/17）虽已被 fill() 的 &0xffff 掩掉，仍显式剔除（latch 位图不积累）。
    // | Bag = Plus, Menu = Minus (pinned on device); their own bits are stripped explicitly.
    if (btn & (1ull << B_BAG)) face |= 1ull << B_PLUS;
    if (btn & (1ull << B_MENU)) face |= 1ull << B_MINUS;
    btn &= ~(1ull << B_BAG | 1ull << B_MENU);
    // 菜单态状态机（纯壳侧，docs §15/§16）：包/单/± 按下 = 进菜单（隐摇杆+技能环）；
    // ✕(B_B) 按下 = 关菜单恢复。城(B_ZR) 不触发（战斗技能）。异步排队防重入。
    // | Menu-mode state machine, shell-side only: bag/menu keys open (hide stick+ring), ✕ closes.
    uint64_t pressed = (btn | face) & ~(_btnBits | _faceBits);
    if ((pressed & ((1ull << B_BAG) | (1ull << B_MENU) | (1ull << B_MINUS) | (1ull << B_PLUS))) && !_menuMode && !_menuPending) {
        _menuPending = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ _menuPending = NO; [self setMenuMode:YES]; });
    } else if ((pressed & (1ull << B_B)) && _menuMode && !_menuPending) {
        _menuPending = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ _menuPending = NO; [self setMenuMode:NO]; });
    }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn | _pulse; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    [self syncGameTouches];
    BOOL sticks = _stick[0] || _stick[1];
    if (changed || sticks || _sticksShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _sticksShown = sticks;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        CGPoint p = [t locationInView:self]; int hit = [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; continue; }
        if (_menuMode) {   // 菜单态点击（§15 路线 A）：中心圆 = A 确认；外围 = 按角度十字键步进一格。
            // 游戏内轮盘/列表都有各自选中高亮，走游戏自己的管线（纯壳侧零游戏内存访问）。
            CGRect f = dm_ios_game_frame();
            CGPoint c = f.size.width > 0
                ? CGPointMake(f.origin.x + f.size.width / 2, f.origin.y + f.size.height / 2)
                : CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
            CGFloat dx = p.x - c.x, dy = p.y - c.y;
            if (hypot(dx, dy) < 0.22 * self.bounds.size.height) [self pulse:B_A];
            else {
                CGFloat a = atan2(dy, dx) * 180 / M_PI;   // UIKit y 向下；上推 = 菜单「上」
                int b = a >= -45 && a < 45 ? B_RIGHT : a >= 45 && a < 135 ? B_DOWN
                      : (a >= 135 || a < -135) ? B_LEFT : B_UP;
                [self pulse:b];
            }
            continue;   // 该触摸不进任何控件/透传（D3 游戏不读触屏）
        }
        // diamond, D-pad, the two sticks: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        if (_d3) { if ([self faceAt:p]) { kind = C_FACE; best = 0; } }   // D3：点中技能环/图标栏具体键才抢，否则透传游戏区（弧外的点击是拾取/移动；固定半径竞争公式够不着技能弧 111u+）
        else { CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; } }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        for (int i = 0; i < (_full ? 2 : 1); i++) if (!_stick[i]) {
            CGFloat s = dist(p, [self stickHome:i]) / ([self stickR:i] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; idx = i; } }
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else { [_owner setObject:@(C_GAME) forKey:t]; [_gtouch addObject:t]; }   // 没碰到任何控件 = 游戏区触摸：透传 | nothing grabbed = game-area touch
    }
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) _stickNow[v >> 8] = p;
    }
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL swap = NO;
    for (UITouch *t in ts) {
        if (ended && ([_owner objectForKey:t].unsignedLongLongValue & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; [_gtouch removeObject:t];
        for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    [self recompute];
    if (swap) {   // 2D → 3D → D3 → 2D 循环（D3 为触控模式专用布局，见 docs/移动端虚拟按键设计.md）
        if (_d3) [self setFull:NO]; else if (_full) [self setD3:YES]; else [self setFull:YES];
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
 - (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; [_gtouch removeAllObjects]; _stick[0] = _stick[1] = nil; [self recompute]; }   // 清空含游戏区触摸（dm_touch_set(0) 由 recompute→syncGameTouches 落地）| clearing the passthrough set lands as an empty dm_touch_set

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

// Rasterize only the small static pieces on a size/scale change. These images
// and layers are shared by every touch refresh; never draw the full overlay.
static UIImage *controlImage(CGSize size,CGFloat scale,void (^draw)(CGContextRef,CGRect)) {
    UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat preferredFormat];format.opaque=NO;format.scale=scale;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx){draw(ctx.CGContext,(CGRect){CGPointZero,size});}];
}
- (void)prepareControlArt {
    CGFloat u=self.u,scale=self.window.screen.scale?:self.contentScaleFactor;
    if(fabs(_artUnit-u)<0.0001&&fabs(_artScale-scale)<0.0001)return;
    _artUnit=u;_artScale=scale;
    CGFloat diameter=2*self.faceR;
    for(int held=0;held<2;held++) {
        _socketArt[held]=controlImage(CGSizeMake(diameter,diameter),scale,^(CGContextRef c,CGRect r){
            if(k_socketTexture) {
                [k_socketTexture drawInRect:r];dm_socket_neutralize(c,r);
                if(held)dm_button_highlight(c,r);
            } else dm_button_draw(c,r,held,0,0);
        });
        for(int i=0;i<2;i++) {
            CGFloat base=2*[self stickR:i],thumb=2*(i?K_RKNOB_R:K_KNOB_R)*u;
            _baseArt[i][held]=controlImage(CGSizeMake(base,base),scale,^(CGContextRef c,CGRect r){dm_joystick_base_draw(c,r,held);});
            _thumbArt[i][held]=controlImage(CGSizeMake(thumb,thumb),scale,^(CGContextRef c,CGRect r){dm_joystick_thumb_draw(c,r,held);});
        }
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat u = self.u;
    [self prepareControlArt];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for(int b=0;b<B_N;b++)_label[b].contentsScale=_artScale;_swapLabel.contentsScale=_artScale;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; CGFloat fr = [self faceKeyR:b]; setPath(_key[b], circlePath(c, fr));
        if(b<=B_Y){_socket[b].frame=CGRectMake(c.x-fr,c.y-fr,2*fr,2*fr);_socket[b].contentsScale=_artScale;}
        placeLabel(_label[b], c, (b == B_A ? 24 : 18) * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    for (int i = 0; i < 2; i++) {
        CGFloat radius=[self stickR:i];_ring[i].bounds=CGRectMake(0,0,2*radius,2*radius);_ring[i].position=[self stickHome:i];_ring[i].contentsScale=_artScale;
        CGFloat k = (i ? K_RKNOB_R : K_KNOB_R) * u; _knob[i].bounds = CGRectMake(0, 0, 2 * k, 2 * k);
        _knob[i].contentsScale=_artScale;CGPathRef shadow=circlePath(CGPointMake(k,k),k*.89);_knob[i].shadowPath=shadow;CGPathRelease(shadow);
    }
    if (_d3) {   // D3 语义标签 + 药水/城键重摆（键 = 真实手柄键，只改几何与标签；映射见 docs/移动端虚拟按键设计.md）
        static NSString *const d3names[B_N] = {@"攻", @"5", @"2", @"3", @"L3", @"R3", @"6", @"4", @"药", @"城", @"+", @"−", @"包", @"单"};
        for (int b = 0; b < B_N; b++) if (d3names[b]) _label[b].string = d3names[b];
        _label[B_B].string = _menuMode ? @"✕" : @"5";   // B_B 双语义（applyLayout 同步切）
        // 药水（B_ZL）：左摇杆右上；城（B_ZR）：右上图标栏最左（泪滴改圆；包/单的图标栏圆由 k_btns 循环按 pillRect D3 分支画出）
        CGPoint pot = [self stickHome:0]; pot.x += 118 * u; pot.y -= 46 * u;
        setPath(_key[B_ZL], circlePath(pot, 26 * u)); placeLabel(_label[B_ZL], pot, 18 * u);
        CGPoint tp = [self d3BarPos:B_ZR];
        setPath(_key[B_ZR], circlePath(tp, K_BAR_R * u)); placeLabel(_label[B_ZR], tp, 18 * u);
        _key[B_ZR].hidden = NO; _label[B_ZR].hidden = NO;
        // 技能弧键（B_R/B_B/B_L 原画在泪滴/pill 位，重画圆到弧位；菜单态 B_B 由 applyLayout 隐弧显图标栏）
        for (int b = 0; b < B_N; b++) { BOOL arc = b == B_R || b == B_B || b == B_L;
            if (!arc) continue;
            BOOL menuHide = _menuMode && b != B_B;
            CGPoint cp = [self facePos:b]; setPath(_key[b], circlePath(cp, [self faceKeyR:b]));
            placeLabel(_label[b], cp, 18 * u);
            _key[b].hidden = menuHide; _label[b].hidden = menuHide;
        }
        for (int i = 0; i < 6; i++) [self updateSkillCd:i];   // 遮罩随布局重摆
    } else {
        for (int i = 0; i < 6; i++) { _skillCd[i].path = NULL; _skillCd[i].hidden = YES; }   // 离开 D3 清遮罩
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−", @"←", @"↑", @"→", @"↓", @"包", @"单"};
        for (int b = 0; b < B_N; b++) if (names[b]) _label[b].string = names[b];
        // 泪滴恢复（drop 形状在上方 k_btns 循环里按默认几何画过；这里恢复 ZL/ZR 位置为标准位）
        for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
            if (!isDrop(b)) continue;
            CGPoint c = [self dropCenter:b]; setPath(_key[b], dropPath(c, [self dropR:b], b == B_ZR || b == B_R ? -M_PI_4 : -3 * M_PI_4, 4 * u));
            placeLabel(_label[b], c, 16 * u); }
    }
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        if(b<=B_Y)_socket[b].contents=(__bridge id)_socketArt[on].CGImage;
        else _key[b].fillColor = (on ? k_on : k_idle).CGColor;
        _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    for (int i = 0; i < 2; i++) {
        CGPoint h = [self stickHome:i], o = [self knobOffset:i];
        BOOL held=_stick[i]!=nil;
        _ring[i].contents=(__bridge id)_baseArt[i][held].CGImage;
        _knob[i].contents=(__bridge id)_thumbArt[i][held].CGImage;
        _knob[i].position = CGPointMake(h.x + o.x, h.y + o.y);
    }
    [CATransaction commit];
}

@end

void dm_gamepad_skill(int slot, float frac);   // hle 层每帧推 D3 技能冷却（slot 0=主攻 1-5=弧键；frac∈[0,1] 剩余比例，<0 无冷却）
void dm_gamepad_skill(int slot, float frac) {
    DmGamepad *v = g_view;
    if (!v || slot < 0 || slot >= 6) return;
    if (fabsf(v->_cdFrac[slot] - frac) < 0.01f) return;   // 1% 节流
    v->_cdFrac[slot] = frac;
    if ([NSThread isMainThread]) [v updateSkillCd:slot];
    else dispatch_async(dispatch_get_main_queue(), ^{ [v updateSkillCd:slot]; });
}

static void physical_present(int present) {
    g_view.hidden = present;
    if (present) { [g_view reset]; dm_input_clear(); }
    dm_hudmove_set_controller(present);   // HUD 移位随物理手柄插拔切换（用户确认的还原约束）| relocation toggles with the pad
}
UIView *dm_gamepad_view(CGRect frame) {
    DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v;
    dm_gamepad_start(physical_present);
    return v;
}
void dm_gamepad_reset(void) {
    // Called on the UIKit main thread by scene focus transitions.
    [g_view reset];
    dm_input_clear();
    dm_physical_gamepad_reset();
}
