// DmSkillAim 单测：安卓 SemanticSkillAim 语义逐项对表（kb/07 §12）。
// phase 0=down 1=move 2=up 3=cancel 4=hold；一槽一手势；超 slop=dragged；未拖长按=hold。
#include <stdio.h>
#include <string.h>
#include "DmSkillAim.h"

static int fails;
#define CHECK(cond, name) do { if (!(cond)) { fails++; printf("FAIL %s\n", name); } else printf("ok %s\n", name); } while (0)

int main(void) {
    DmSkillAim a; memset(&a, 0, sizeof a);

    // 1 begin → down 事件，radius/slop 透传
    CHECK(dmaim_begin(&a, 1, 2, 100, 100, 94, 12) == 1, "begin ok");
    DmAimEvent ev[8]; int n = dmaim_drain(&a, ev, 8);
    CHECK(n == 1 && ev[0].phase == 0 && ev[0].slot == 2 && ev[0].ox == 100 && ev[0].radius == 94, "down event");

    // 2 slop 内 move → 未 dragged
    CHECK(dmaim_move(&a, 1, 108, 100) == 1, "move in slop");   // 8 < 12
    n = dmaim_drain(&a, ev, 8);
    CHECK(n == 1 && ev[0].phase == 1 && ev[0].dragged == 0, "move event not dragged");

    // 3 超 slop → dragged
    dmaim_move(&a, 1, 120, 100);   // 20 > 12
    n = dmaim_drain(&a, ev, 8);
    CHECK(n == 1 && ev[0].dragged == 1, "beyond slop = dragged");

    // 4 dragged 后 hold 拒绝
    CHECK(dmaim_can_hold(&a, 1) == 0, "dragged cannot hold");
    CHECK(dmaim_hold(&a, 1) == 0, "hold rejected after drag");

    // 5 end → up 事件
    CHECK(dmaim_end(&a, 1) == 1, "end ok");
    n = dmaim_drain(&a, ev, 8);
    CHECK(n == 1 && ev[0].phase == 2, "up event");

    // 6 未拖长按 → hold 事件
    dmaim_begin(&a, 2, 0, 50, 50, 54, 12);
    dmaim_drain(&a, ev, 8);
    CHECK(dmaim_can_hold(&a, 2) == 1, "fresh can hold");
    CHECK(dmaim_hold(&a, 2) == 1, "hold ok");
    n = dmaim_drain(&a, ev, 8);
    CHECK(n == 1 && ev[0].phase == 4, "hold event");
    CHECK(dmaim_hold(&a, 2) == 0, "double hold rejected");

    // 7 一槽一手势：同槽第二指拒绝
    CHECK(dmaim_begin(&a, 3, 0, 60, 60, 54, 12) == 0, "same slot rejected");
    CHECK(dmaim_begin(&a, 3, 1, 60, 60, 54, 12) == 1, "other slot ok");
    dmaim_cancel_all(&a);

    // 8 同指重复 begin → 旧手势 cancel
    dmaim_begin(&a, 4, 1, 0, 0, 54, 12);
    dmaim_drain(&a, ev, 8);
    dmaim_begin(&a, 4, 3, 0, 0, 54, 12);
    n = dmaim_drain(&a, ev, 8);
    CHECK(n == 2 && ev[0].phase == 3 && ev[0].slot == 1 && ev[1].phase == 0 && ev[1].slot == 3,
          "re-begin cancels old gesture first");

    // 9 非法参数拒绝（slot 越界/radius<=0/slop<0）
    CHECK(dmaim_begin(&a, 5, 6, 0, 0, 54, 12) == 0, "slot>=6 rejected");
    CHECK(dmaim_begin(&a, 5, 0, 0, 0, 0, 12) == 0, "radius<=0 rejected");
    CHECK(dmaim_begin(&a, 5, 0, 0, 0, 54, -1) == 0, "slop<0 rejected");

    // 10 cancel 指定指
    dmaim_cancel_one(&a, 5);
    n = dmaim_drain(&a, ev, 8);
    CHECK(n == 0, "cancel nonexistent = no event");
    dmaim_begin(&a, 6, 4, 0, 0, 54, 12);
    dmaim_drain(&a, ev, 8);   // 先排空 down
    dmaim_cancel_one(&a, 6);
    n = dmaim_drain(&a, ev, 8);
    CHECK(n == 1 && ev[0].phase == 3, "cancel emits phase 3");

    printf(fails ? "SKILL_AIM FAIL %d\n" : "SKILL_AIM OK\n", fails);
    return fails != 0;
}
