// DmTouchSlots 单测：安卓 TouchSlots.java 语义逐项对表。
// | Slot allocation, retain release, refill reuse, exhaustion.
#include <stdio.h>
#include "DmTouchSlots.h"

static int fails;
#define CHECK(cond, name) do { if (!(cond)) { fails++; printf("FAIL %s\n", name); } else printf("ok %s\n", name); } while (0)

int main(void) {
    DmTouchSlots s;
    dmts_init(&s);

    // 1 首次分配：顺序开槽 0,1,2
    CHECK(dmts_slot(&s, 10) == 0, "first id takes slot 0");
    CHECK(dmts_slot(&s, 20) == 1, "second id takes slot 1");
    CHECK(dmts_slot(&s, 30) == 2, "third id takes slot 2");

    // 2 已占 id → 原槽（稳定）
    CHECK(dmts_slot(&s, 20) == 1, "existing id keeps slot");

    // 3 retain 收缩：20 消失 → 槽 1 释放；再分配复用
    int act[2] = { 10, 30 };
    dmts_retain(&s, act, 2);
    CHECK(dmts_slot(&s, 40) == 1, "released slot reused first");

    // 4 负 id 拒绝
    CHECK(dmts_slot(&s, -5) == -1, "negative id rejected");

    // 5 满 16 槽后 → -1
    DmTouchSlots f;
    dmts_init(&f);
    for (int i = 0; i < 16; i++) CHECK(dmts_slot(&f, 100 + i) == i, "fill slot");
    CHECK(dmts_slot(&f, 999) == -1, "exhausted = -1");

    // 6 retain 空集 → 全释放
    dmts_retain(&f, NULL, 0);
    CHECK(dmts_slot(&f, 7) == 0, "empty retain clears all");

    printf(fails ? "TOUCH_SLOTS FAIL %d\n" : "TOUCH_SLOTS OK\n", fails);
    return fails != 0;
}
