// 触控面几何实现（DmTouchLayout.h）。右组控件表 = 安卓 SCV:1116-1143 设计坐标原样；
// 弧键坐标运行时按公式算（180°+32.5°i，弧心 (1650,777)，r220/键 54）。
// 包/单顶排与摇杆是视图锚定/动态落点，不进本表（DmGamepad.m 自己管，保持已验证行为）。
// | Right-group control table with the Android design coordinates; arc points
// | computed from the formula. Top row & joystick stay view-anchored in DmGamepad.
#include "DmTouchLayout.h"
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

bool dm_tl_canvas(const DmTlView *v, DmTlCanvas *out) {
    double availW = v->viewW - v->left - v->right;
    double availH = v->viewH - v->top - v->bottom;
    if (availW <= 0 || availH <= 0) return false;
    double s = fmin(availW / DM_CANVAS_W, availH / DM_CANVAS_H);
    if (!(s > 0)) return false;
    out->scale = s;
    out->availW = availW; out->availH = availH;
    out->groupX = v->left + availW - DM_CANVAS_W * s;   // SCV:1098 右组锚 = 安全区右下角收进画布
    out->groupY = v->top + availH - DM_CANVAS_H * s;
    return true;
}

void dm_tl_point(const DmTlCanvas *c, double designX, double designY, bool inGroup, double *outX, double *outY) {
    double ax = inGroup ? c->groupX : 0, ay = inGroup ? c->groupY : 0;
    *outX = ax + designX * c->scale;
    *outY = ay + designY * c->scale;
}

double dm_tl_min_hit(const DmTlCanvas *c, double density, double canvasRadius, bool topRow) {
    (void)canvasRadius;   // 最小命中只看画布缩放/密度（半径下限并进调用方 hit 的 fmax）
    // SCV:1097-1110：minTap=min(24*density, 60*scale)、topTap=min(minTap,50*scale)、actionTap=min(minTap,49*scale)
    double minTap = fmin(24 * density, 60 * c->scale);
    if (topRow) return fmin(minTap, 50 * c->scale);
    return fmin(minTap, 49 * c->scale);
}

int dm_tl_default_controls(DmTlControl *out, int cap) {
    static const int arcSlots[5] = DM_SKILL_SLOTS_ON_ARC;
    int n = 0;
    if (cap < 11) return -1;
    // 攻击键 = 技能槽2（A），SCV:1119 (1650,735) r94
    out[n++] = (DmTlControl){ "skill.primary", DM_KIND_BUTTON, 2, 0, DMKJ_A, 1650.0, 735.0, DM_ATK_R, true };
    // 弧 5 键（SCV:1121-1138）
    for (int i = 0; i < 5; i++) {
        double a = DM_ARC_ANGLE_DEG(i) * M_PI / 180.0;
        static const char *arcKeys[5] = { "skill.2", "skill.3", "skill.4", "skill.5", "skill.6" };
        out[n++] = (DmTlControl){ arcKeys[i], DM_KIND_BUTTON, arcSlots[i], 0,
                                  DM_SKILL_SLOT_KEY(arcSlots[i]),
                                  1650.0 + DM_ARC_RADIUS * cos(a), 777.0 + DM_ARC_RADIUS * sin(a), DM_ARC_KEY_R, true };
    }
    // 药水（R1）SCV:1117 (1300,645)；回城（DPad 右）SCV:1116 (1300,777)
    out[n++] = (DmTlControl){ "potion", DM_KIND_BUTTON, -1, DMK_R, DMKJ_R, 1300.0, 645.0, DM_SMALL_R, true };
    out[n++] = (DmTlControl){ "portal", DM_KIND_BUTTON, -1, DMK_RIGHT, DMKJ_RIGHT, 1300.0, 777.0, DM_SMALL_R, true };
    // 闪避 SCV:1118 (1800,425)——无掩码，动作=探测性 L 键（DmGamepad 决定）；拾取 SCV:1141-1143 (1685,425) 无动作灰显
    out[n++] = (DmTlControl){ "evade", DM_KIND_EVADE, -1, 0, DMKJ_L, 1800.0, 425.0, DM_SMALL_R, true };
    out[n++] = (DmTlControl){ "pickup", DM_KIND_PICKUP, -1, 0, DMKJ_PICKUP, 1685.0, 425.0, DM_SMALL_R, true };
    return n;   // 10 条
}

bool dm_tl_hit(const DmTlControl *ctl, const DmTlCanvas *c, double density,
               double viewX, double viewY, double extraHit, double *outDist) {
    double x, y;
    dm_tl_point(c, ctl->x, ctl->y, ctl->inGroup, &x, &y);
    double d = hypot(viewX - x, viewY - y);
    if (outDist) *outDist = d;
    double hit = fmax(ctl->r * c->scale, dm_tl_min_hit(c, density, ctl->r, false));
    if (extraHit > 0) hit = fmax(hit, extraHit);
    return d <= hit * 1.15;   // DmGamepad 现行 1.15 倍容差（与安卓 hitRadius 语义合并）
}

bool dm_tl_stick_zone(const DmTlView *v, double viewX, double viewY) {
    double availH = v->viewH - v->top - v->bottom;
    return viewX < v->left + 0.40 * (v->viewW - v->left - v->right) &&
           viewY > v->top + 0.5 * availH;   // SCV:1083-1086（x 上限 0.4 沿用 iOS 现行 45%→收紧到安卓 40%）
}
