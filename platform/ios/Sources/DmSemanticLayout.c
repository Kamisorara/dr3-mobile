// 安卓 SemanticControlsView$Control+$Layout 忠实 C 移植（2026-11-10 触控重构轮，kb/07 §12）。
// | Faithful C port of the Android Layout engine — circle list, safe-area resolve, hit test.
#include "DmSemanticLayout.h"
#include <math.h>

static void clampf(float *v, float lo, float hi) { if (*v < lo) *v = lo; if (*v > hi) *v = hi; }

// 安卓 Layout.circle：Control(left + x*unit, top + y*unit, r*unit)，hitRadius=max(r*unit, minimumRadius)
static void circle(DmSemLayout *L, float left, float top, float unit, int kind,
                   unsigned long long button, int slot, float x, float y, float r, float minimumRadius) {
    if (L->n >= 16) return;
    DmSemControl *c = &L->c[L->n++];
    c->kind = kind; c->button = button; c->slot = slot;
    c->x = left + x * unit; c->y = top + y * unit;
    c->halfW = r * unit; c->halfH = r * unit;
    c->hitRadius = c->halfW > minimumRadius ? c->halfW : minimumRadius;
    c->enabled = 1; c->held = 0;
}

void dm_semlayout_build(DmSemLayout *L, float width, float height, float density,
                        int left, int top, int right, int bottom,
                        int worldControls, float rightMargin, int includePickup) {
    float availW = width - left - right; if (availW < 0) availW = 0;
    float availH = height - top - bottom; if (availH < 0) availH = 0;
    float scale = fminf(availW / 1851.0f, availH / 849.0f);
    float unit = fminf(density, fminf(availW / 720.0f, availH / 400.0f));
    L->scale = scale; L->unit = unit > 0 ? unit : 0;
    // 摇杆认领区（安卓 region：left..left+0.4*availW × top+0.5*availH..top+availH）——空布局也保留
    L->stickL = (float)left;
    L->stickT = (float)top + 0.5f * availH;
    L->stickR = (float)left + 0.4f * availW;
    L->stickB = (float)top + availH;
    L->n = 0;
    if (scale <= 0.0f || unit <= 0.0f || !worldControls) return;   // 安卓：controls = new Control[0]

    float minTap = fminf(24.0f * density, 60.0f * scale);
    float actionTap = fminf(minTap, 49.0f * scale);   // 安卓 actionTap：右组命中下限（此前误用 minTap）
    float groupLeft = ((float)left + availW) - scale * 1851.0f;    // 右组锚右下
    float groupTop = ((float)top + availH) - scale * 849.0f;
    float topTap = fminf(minTap, scale * 50.0f);
    float topHit = fmaxf(scale * 42.0f, topTap);
    float toolbarLimit = ((float)width - ((float)height * 240.0f) / 720.0f) - 1.0f;
    float menuX = fminf(((float)width - (float)right) - topHit, toolbarLimit - (16.0f * scale) - topHit);
    float bagX = menuX - (2.0f * topHit) - (12.0f * scale);
    // 顺序 = 安卓 list 顺序（hit 倒序 → 后加者优先）
    circle(L, bagX, (float)top, scale, 2, 1024ull, -1, 0.0f, 64.0f, 42.0f, topTap);          // 包
    circle(L, menuX, (float)top, scale, 2, 2048ull, -1, 0.0f, 64.0f, 42.0f, topTap);         // 单
    circle(L, (float)left, groupTop, scale, 0, 0ull, -1, 190.0f, 620.0f, 123.0f, minTap);    // 摇杆
    circle(L, groupLeft, groupTop, scale, 2, 16384ull, -1, 1300.0f, 777.0f, 48.0f, actionTap);  // 回城
    circle(L, groupLeft, groupTop, scale, 2, 128ull, -1, 1300.0f, 645.0f, 48.0f, actionTap);    // 药水
    circle(L, groupLeft, groupTop, scale, 3, 0ull, -1, 1800.0f, 425.0f, 48.0f, actionTap);      // 闪避
    circle(L, groupLeft, groupTop, scale, 2, 1ull, 2, 1650.0f, 829.0f - 94.0f, 94.0f, actionTap);// 攻击 A（slot2）
    {   // 弧 5 键：slots{5,0,3,1,4} masks{512,8,4,2,256}，圆心(1650,777) 轨道 220，角 180°+32.5°i（安卓同表）
        static const int slots[5] = {5, 0, 3, 1, 4};
        static const unsigned long long masks[5] = {512, 8, 4, 2, 256};
        for (int i = 0; i < 5; i++) {
            double ang = ((double)i * 32.5 + 180.0) * 3.14159265358979323846 / 180.0;
            float ax = 1650.0f + (float)(220.0 * cos(ang));
            float ay = 777.0f + (float)(220.0 * sin(ang));
            circle(L, groupLeft, groupTop, scale, 2, masks[i], slots[i], ax, ay, 54.0f, actionTap);
        }
    }
    if (includePickup)
        circle(L, groupLeft, groupTop, scale, 4, 0ull, -1, 1685.0f, 425.0f, 48.0f, actionTap);  // 拾取

    // 安卓 profile=null 基线 resolve：右组（kind≠0 且 button≠1024/2048）x -= rightMargin*unit，
    // 再 clamp 进安全区（radius 夹在 safe 半径内）。rightMargin ∈ [0,96]×unit 由调用方 clamp。
    float safeL = (float)left, safeT = (float)top, safeR = (float)width - (float)right, safeB = (float)height - (float)bottom;
    float safeW = safeR - safeL, safeH = safeB - safeT;
    if (safeW <= 0 || safeH <= 0) return;
    float half = fminf(safeW, safeH) / 2.0f;
    float offset = -rightMargin * unit;
    for (int i = 0; i < L->n; i++) {
        DmSemControl *c = &L->c[i];
        int rightGroup = !(c->kind == 0 || c->button == 1024 || c->button == 2048);
        float rad = fminf(half, c->halfW > 0 ? c->halfW : 1.0f);
        if (rightGroup) c->x += offset;
        clampf(&c->x, safeL + rad, safeR - rad);
        clampf(&c->y, safeT + rad, safeB - rad);
    }
}

int dm_semlayout_hit(const DmSemLayout *L, float x, float y) {
    int stick = -1;
    for (int i = L->n - 1; i >= 0; i--) {
        const DmSemControl *c = &L->c[i];
        if (!c->enabled) continue;
        if (c->kind == 0) stick = i;
        else {
            float dx = x - c->x, dy = y - c->y;
            if (dx * dx + dy * dy <= c->hitRadius * c->hitRadius) return i;
        }
    }
    if (stick < 0 || x < L->stickL || x > L->stickR || y < L->stickT || y > L->stickB) return -1;
    return stick;
}

float dm_semlayout_role_bottom(const DmSemLayout *L, float viewH) {
    if (viewH <= 0) return -1.0f;
    float bottom = -1.0f;
    for (int i = 0; i < L->n; i++) {
        const DmSemControl *c = &L->c[i];
        if (c->enabled && c->button != 1024 && c->button != 2048) {
            float b = c->y + c->halfH;
            if (b > bottom) bottom = b;
        }
    }
    if (bottom < 0) return -1.0f;
    return bottom / viewH;
}
