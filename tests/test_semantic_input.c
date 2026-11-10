// DmSemanticInput 单测：安卓 SemanticInput 语义逐项对表（kb/07 §12）。
// 重点：死区 0.12 线性 remap（无饱和点）、dy 取反（上=正）、evade 向量=左摇杆方向。
#include <stdio.h>
#include <math.h>
#include "DmSemanticInput.h"

static int fails;
#define CHECK(cond, name) do { if (!(cond)) { fails++; printf("FAIL %s\n", name); } else printf("ok %s\n", name); } while (0)

int main(void) {
    DmSemInput s;
    dmsi_init(&s);

    // 1 死区内 → 0
    dmsi_begin_stick(&s, 1, 0, 100, 100, 50);
    dmsi_move(&s, 1, 104, 100);   // mag = 4/50 = 0.08 < 0.12
    CHECK(s.sticks[0].x == 0 && s.sticks[0].y == 0, "inside dead zone = 0");

    // 2 线性 remap：mag=0.56 → out = (0.56-0.12)/0.88*32767 ≈ 16383.5；dy 取反（上移=+y）
    dmsi_move(&s, 1, 100, 100 - 28);   // dist=28, mag=0.56, 方向正上
    double expect = (0.56 - 0.12) / 0.88 * 32767.0;
    CHECK(s.sticks[0].x == 0 && fabs((double)s.sticks[0].y - expect) < 1.0, "linear remap, up = +y");

    // 3 满拨（mag=1）→ 32767（安卓无 0.72 饱和点）
    dmsi_move(&s, 1, 100, 100 - 50);
    CHECK(s.sticks[0].y == 32767, "full deflection = 32767");

    // 4 第二指 begin 同摇杆 → 拒绝（owner 已占）
    CHECK(dmsi_begin_stick(&s, 2, 0, 200, 200, 50) == 0, "second finger rejected");

    // 5 press/release：位图 OR + 释放清摇杆
    dmsi_press(&s, 3, 1 | 8);   // A|Y
    dmsi_press(&s, 4, 512);     // ZR
    DmSemState st = dmsi_snapshot(&s);
    CHECK(st.buttons == (1 | 8 | 512), "buttons OR");
    CHECK(st.lx == 0 && st.ly == 32767, "left stick in snapshot");
    dmsi_release(&s, 1);
    st = dmsi_snapshot(&s);
    CHECK(st.buttons == (1 | 8 | 512) && st.ly == 0, "release clears stick only");

    // 6 evade：左摇杆方向归一 ×32767
    dmsi_begin_stick(&s, 5, 0, 0, 0, 50);
    dmsi_move(&s, 5, 0, -50);   // 正上满拨
    dmsi_evade(&s);
    DmSemState pub = dmsi_publication(&s);
    CHECK(pub.evadeN == 2 && pub.evade[0] == 0 && pub.evade[1] == 32767, "evade vector = stick dir");
    // 7 publication 排空：第二次无向量
    pub = dmsi_publication(&s);
    CHECK(pub.evadeN == 0, "evades drained");
    // 8 无摇杆 evade → 0,0 对
    dmsi_release(&s, 5);
    dmsi_evade(&s);
    pub = dmsi_publication(&s);
    CHECK(pub.evadeN == 2 && pub.evade[0] == 0 && pub.evade[1] == 0, "idle evade = 0,0");

    // 9 cancel：位图清空 + 摇杆清空 + cancelEvades 置位一次
    dmsi_press(&s, 9, 2);
    dmsi_begin_stick(&s, 10, 0, 0, 0, 10);
    dmsi_cancel(&s);
    st = dmsi_snapshot(&s);
    CHECK(st.buttons == 0 && st.lx == 0 && st.ly == 0, "cancel clears");
    pub = dmsi_publication(&s);
    CHECK(pub.cancelEvades == 1, "cancelEvades flagged");
    pub = dmsi_publication(&s);
    CHECK(pub.cancelEvades == 0, "cancelEvades consumed");

    // 10 release 清该指 held
    dmsi_press(&s, 11, 4);
    dmsi_release(&s, 11);
    CHECK(dmsi_snapshot(&s).buttons == 0, "release clears held");

    printf(fails ? "SEMANTIC_INPUT FAIL %d\n" : "SEMANTIC_INPUT OK\n", fails);
    return fails != 0;
}
