// 触控面几何单测：DmTouchLayout 的画布/控件表/命中与安卓 SemanticControlsView 规格逐项对表
// （弧键坐标按公式独立重算，不抄实现；期望值由 tests/test_touch_layout.py 双写互证）。
// | Touch-layout geometry unit test: canvas transform, control table, hit tests,
// | cross-checked against the Android spec. Expected values recomputed independently.
#include <stdio.h>
#include <math.h>
#include "DmTouchLayout.h"

static int fails;
#define CHECK(cond, name) do { if (!(cond)) { fails++; printf("FAIL %s\n", name); } else printf("ok %s\n", name); } while (0)
static void near(double got, double want, const char *name) {
    if (fabs(got - want) > 0.01) { fails++; printf("FAIL %s: got %.3f want %.3f\n", name, got, want); }
    else printf("ok %s (%.3f)\n", name, got);
}

int main(void) {
    // ---- 画布：视图 2000×1000 无安全区内缩 → scale=min(2000/1851, 1000/849)=2000/1851 ----
    DmTlView v = {0, 0, 0, 0, 2000, 1000, 1};
    DmTlCanvas c;
    CHECK(dm_tl_canvas(&v, &c), "canvas ok");
    near(c.scale, 2000.0 / 1851.0, "scale = min(2000/1851, 1000/849) = 2000/1851");
    near(c.groupX, 2000 - 1851.0 * (2000.0 / 1851.0), "groupX = availW - 1851*s");
    near(c.groupY, 1000 - 849.0 * (2000.0 / 1851.0), "groupY = availH - 849*s");

    // ---- 控件表：10 条，攻击键 (1650,735) r94 槽2=A；弧5键公式重算；药/城/闪/拾 r48 ----
    DmTlControl ctl[12];
    int n = dm_tl_default_controls(ctl, 12);
    CHECK(n == 10, "default controls = 10");
    near(ctl[0].x, 1650, "attack design x");
    near(ctl[0].y, 735, "attack design y");
    near(ctl[0].r, 94, "attack r94");
    CHECK(ctl[0].slot == 2 && ctl[0].button == DMKJ_A, "attack = slot2/A");
    double ang[5];
    for (int i = 0; i < 5; i++) ang[i] = (180.0 + 32.5 * i) * 3.14159265358979323846 / 180.0;
    static const int arcSlots[5] = {5, 0, 3, 1, 4};
    static const int arcKeys[5] = {DMKJ_ZR, DMKJ_Y, DMKJ_X, DMKJ_B, DMKJ_ZL};
    for (int i = 0; i < 5; i++) {
        DmTlControl *a = &ctl[1 + i];
        char nm[64];
        snprintf(nm, sizeof nm, "arc%d design x", i);
        near(a->x, 1650 + 220 * cos(ang[i]), nm);
        snprintf(nm, sizeof nm, "arc%d design y", i);
        near(a->y, 777 + 220 * sin(ang[i]), nm);
        CHECK(a->slot == arcSlots[i], "arc slot order 5/0/3/1/4");
        CHECK(a->button == arcKeys[i], "arc key ZR/Y/X/B/ZL");
        CHECK(a->r == 54, "arc key r54");
    }
    near(ctl[6].y, 645, "potion y645");
    CHECK(ctl[6].button == DMKJ_R && ctl[6].r == 48, "potion = R1 r48");
    CHECK(ctl[7].button == DMKJ_RIGHT, "portal = DPad right（城键迁出 ZL）");
    CHECK(ctl[8].button == DMKJ_L, "evade = 探测性 L");
    CHECK(ctl[9].button == DMKJ_PICKUP, "pickup 灰显位");

    // ---- 槽→键映射（kb/07 §7 实证：0:Y 1:B 2:A 3:X 4:ZL 5:ZR）----
    CHECK(DM_SKILL_SLOT_KEY(0) == DMKJ_Y, "slot0 = Y");
    CHECK(DM_SKILL_SLOT_KEY(1) == DMKJ_B, "slot1 = B");
    CHECK(DM_SKILL_SLOT_KEY(2) == DMKJ_A, "slot2 = A");
    CHECK(DM_SKILL_SLOT_KEY(3) == DMKJ_X, "slot3 = X");
    CHECK(DM_SKILL_SLOT_KEY(4) == DMKJ_ZL, "slot4 = ZL");
    CHECK(DM_SKILL_SLOT_KEY(5) == DMKJ_ZR, "slot5 = ZR");

    // ---- 视图坐标：scale=1000/849 时攻击键屏位置 = group + design*scale ----
    double sx, sy;
    dm_tl_point(&c, ctl[0].x, ctl[0].y, true, &sx, &sy);
    near(sx, c.groupX + 1650 * c.scale, "attack screen x = group + 1650*s");
    near(sy, c.groupY + 735 * c.scale, "attack screen y = group + 735*s");

    // ---- 命中：攻击键屏心 1.15 倍内命中、外不中 ----
    double ax, ay;
    dm_tl_point(&c, ctl[0].x, ctl[0].y, true, &ax, &ay);
    double d;
    CHECK(dm_tl_hit(&ctl[0], &c, 1, ax, ay, 0, &d), "hit at center");
    CHECK(dm_tl_hit(&ctl[0], &c, 1, ax + ctl[0].r * c.scale, ay, 0, &d), "hit at edge ×1");
    CHECK(!dm_tl_hit(&ctl[0], &c, 1, ax + ctl[0].r * c.scale * 1.3, ay, 0, &d), "miss beyond 1.15×");

    // ---- 摇杆区：左半下部在内、右上在外 ----
    DmTlView v2 = {0, 0, 0, 0, 2000, 1000, 1};
    CHECK(dm_tl_stick_zone(&v2, 300, 900), "stick zone lower-left");
    CHECK(!dm_tl_stick_zone(&v2, 1500, 900), "right side outside");
    CHECK(!dm_tl_stick_zone(&v2, 300, 300), "upper half outside");

    printf(fails ? "TOUCH_LAYOUT FAIL %d\n" : "TOUCH_LAYOUT OK\n", fails);
    return fails != 0;
}
