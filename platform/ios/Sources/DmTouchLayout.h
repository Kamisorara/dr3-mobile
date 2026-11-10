// 触控面几何（纯函数，无 UIKit 依赖，供单测）：照搬安卓 SemanticControlsView.Layout 的
// 设计画布与控件表（规格书 kb/17 §6 同源；行号语义 = 安卓 SemanticControlsView.java）。
// 设计画布 1851×849，右组锚安全区右下角；控件中心 = 锚点 + 设计坐标 × scale。
// | Touch-layout geometry (pure functions, unit-testable): port of the Android
// | SemanticControlsView.Layout — 1851×849 design canvas, right group anchored
// | to the safe-area bottom-right, control centers = anchor + design × scale.
#pragma once
#include <math.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DM_CANVAS_W 1851.0
#define DM_CANVAS_H 849.0

// 按钮位（= dm_input.h 的 nn::hid NpadButton 位序；16 之后是壳内伪键，不进 Npad）
enum {
    DMK_A = 1u << 0, DMK_B = 1u << 1, DMK_X = 1u << 2, DMK_Y = 1u << 3,
    DMK_LS = 1u << 4, DMK_RS = 1u << 5, DMK_L = 1u << 6, DMK_R = 1u << 7,
    DMK_ZL = 1u << 8, DMK_ZR = 1u << 9, DMK_PLUS = 1u << 10, DMK_MINUS = 1u << 11,
    DMK_LEFT = 1u << 12, DMK_UP = 1u << 13, DMK_RIGHT = 1u << 14, DMK_DOWN = 1u << 15,
};

// kind（安卓 SCV:26-29）
enum { DM_KIND_STICK = 0, DM_KIND_BUTTON = 2, DM_KIND_EVADE = 3, DM_KIND_PICKUP = 4 };

// 控件标识（伪键从 16 起：B_SEASON 供赛季面板，B_NONE = 无键纯展示）
enum {
    DMKJ_A = 0, DMKJ_B, DMKJ_X, DMKJ_Y, DMKJ_LS, DMKJ_RS, DMKJ_L, DMKJ_R,
    DMKJ_ZL, DMKJ_ZR, DMKJ_PLUS, DMKJ_MINUS, DMKJ_LEFT, DMKJ_UP, DMKJ_RIGHT, DMKJ_DOWN,
    DMKJ_SEASON = 16, DMKJ_PICKUP = 17, DMKJ_NONE = 31,
};

// 游戏技能槽 → Npad 键（kb/07 §7 真机 HUD + 安卓 SkillFeedback.target() 实证：
// 槽0=Y 槽1=B 槽2=A 槽3=X 槽4=ZL 槽5=ZR；药水=R1）。弧键排布（安卓 SCV:1121-1138）：
// 弧 i=0..4 = 槽 {5,0,3,1,4}，角 = 180° + 32.5°×i，半径 220，键半径 54；攻击 = 槽2 半径 94。
#define DM_SKILL_SLOT_KEY(slot) \
    ((slot) == 0 ? DMKJ_Y : (slot) == 1 ? DMKJ_B : (slot) == 2 ? DMKJ_A : \
     (slot) == 3 ? DMKJ_X : (slot) == 4 ? DMKJ_ZL : (slot) == 5 ? DMKJ_ZR : DMKJ_NONE)
#define DM_SKILL_SLOTS_ON_ARC {5, 0, 3, 1, 4}
#define DM_ARC_ANGLE_DEG(i) (180.0 + 32.5 * (i))
#define DM_ARC_RADIUS 220.0
#define DM_ARC_KEY_R 54.0
#define DM_ATK_R 94.0
#define DM_SMALL_R 48.0

// 画布 → 视图：安全区内 scale = min(availW/1851, availH/849)，右组锚右下（SCV:1075-1099）
typedef struct {
    double left, top, right, bottom;   // 视图安全区（ insets）
    double viewW, viewH;
    double density;                    // pt→px 比例的近似（minTap 用；UIKit 传 1，几何只影响最小命中）
} DmTlView;

typedef struct {
    double scale;                      // 画布缩放
    double groupX, groupY;             // 右组锚点（视图坐标）
    double availW, availH;
} DmTlCanvas;

bool  dm_tl_canvas(const DmTlView *v, DmTlCanvas *out);
void  dm_tl_point(const DmTlCanvas *c, double designX, double designY, bool inGroup, double *outX, double *outY);
double dm_tl_min_hit(const DmTlCanvas *c, double density, double canvasRadius, bool topRow);

// 控件描述符（固定表，构造一次）
typedef struct {
    const char *key;        // 语义键（安卓 Control.key()）：move/skill.primary/...；NULL = 摇杆/拾取等无保存键
    int kind;               // DM_KIND_*
    int slot;               // 技能槽 0..5，-1 非技能
    unsigned mask;          // Npad 掩码（技能/evade/pickup/season 为 0，不走普通掩码）
    int button;             // DMKJ_* 键号
    double x, y, r;         // 设计坐标中心与半径（摇杆 x 相对安全区左、y 相对右组顶；其余组内坐标）
    bool inGroup;
} DmTlControl;

// 默认控件表（安卓 SCV:1105-1143 的坐标原样；返回条数，*out ≤ 15）
int   dm_tl_default_controls(DmTlControl *out, int cap);

// 圆形命中（SCV:964-975）：dx²+dy² ≤ hitRadius²
bool  dm_tl_hit(const DmTlControl *ctl, const DmTlCanvas *c, double density,
                double viewX, double viewY, double extraHit, double *outDist);
// 摇杆活动区（SCV:1083-1086）：安全区左半下部（x<40%W、y>50%H）
bool  dm_tl_stick_zone(const DmTlView *v, double viewX, double viewY);

#ifdef __cplusplus
}
#endif
