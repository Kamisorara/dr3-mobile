// UI 指针状态机单测：DmUiPointer（安卓 UiPointer.java C 移植）语义逐项对表。
// | UI pointer state machine unit tests, checked item-by-item against Android semantics.
#include <stdio.h>
#include <string.h>
#include "DmUiPointer.h"

static int fails;
#define CHECK(cond, name) do { if (!(cond)) { fails++; printf("FAIL %s\n", name); } else printf("ok %s\n", name); } while (0)

int main(void) {
    DmUip p; dm_uip_init(&p);
    DmUipEvent ev; long long oms = 0, ms = 100;
    int ids[4]; float xs[4], ys[4];

    // 1 新主指按下 → 单指 phase 0
    ids[0] = 11; xs[0] = 0.2f; ys[0] = 0.3f;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) && ev.phase == 0 && !ev.paired
          && ev.x == 0.2f && ev.y == 0.3f, "fresh down = single phase 0");

    // 2 坐标变了 → move 1
    xs[0] = 0.25f;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) && ev.phase == 1, "move = phase 1");

    // 3 坐标没变 → 无事件
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) == 0, "no move = no event");

    // 4 第二指出现 → 双指对 down（phase 0, paired）
    ids[1] = 12; xs[1] = 0.6f; ys[1] = 0.7f;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 2, 0, ms, &oms, &ev) && ev.phase == 0 && ev.paired
          && ev.bx == 0.6f && ev.by == 0.7f, "second finger = pair down");

    // 5 双指移动 → pair move
    xs[1] = 0.62f;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 2, 0, ms, &oms, &ev) && ev.phase == 1 && ev.paired, "pair move = phase 1 pair");

    // 6 第二指抬起 → pair up + waitForRelease
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) && ev.phase == 2 && ev.paired, "pair lift = pair up");
    ids[0] = 11; xs[0] = 0.3f; ys[0] = 0.4f;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) == 0, "waitForRelease ignores new touches");

    // 7 全部抬起 → 队列清；新触点重新 down
    ids[0] = 11;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 0, 0, ms, &oms, &ev) == 0, "all up = quiet");
    ids[0] = 21; xs[0] = 0.1f; ys[0] = 0.9f;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) && ev.phase == 0, "new primary after release = down");

    // 8 主指失联 → up + waitForRelease（安卓：防误触）
    ids[0] = 22; xs[0] = 0.5f; ys[0] = 0.5f;   // 集里没有主指 21
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) && ev.phase == 2, "primary lost = up");
    ids[0] = 22;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) == 0, "waitForRelease after loss");

    // 9 抬完恢复
    CHECK(dm_uip_publish(&p, ids, xs, ys, 0, 0, ms, &oms, &ev) == 0, "drain quiet");
    ids[0] = 31; xs[0] = 0.4f; ys[0] = 0.4f;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) && ev.phase == 0, "recovered down");

    // 10 系统取消 → 恒发 phase 3
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 1, ms, &oms, &ev) && ev.phase == 3, "cancel emits phase 3");

    // 11 空集 cancel 也发 phase 3（安卓 cancel() 无条件 emit）
    memset(&p, 0, sizeof p);
    CHECK(dm_uip_publish(&p, ids, xs, ys, 0, 1, ms, &oms, &ev) && ev.phase == 3, "idle cancel emits phase 3");

    // 12 out_ms 透传
    ms = 1234;
    ids[0] = 41; xs[0] = 0.1f; ys[0] = 0.1f;
    CHECK(dm_uip_publish(&p, ids, xs, ys, 1, 0, ms, &oms, &ev) && oms == 1234, "event ms passthrough");

    printf(fails ? "UI_POINTER FAIL %d\n" : "UI_POINTER OK\n", fails);
    return fails != 0;
}
