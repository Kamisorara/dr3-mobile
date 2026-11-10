// DmSemanticRoute 单测：安卓 SemanticControlsView$Route 语义逐项对表（kb/07 §12）。
// | Route tests: allocation, held counting, stick tap 350ms, generation reset, cancel.
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "DmSemanticRoute.h"

static int fails;
#define CHECK(cond, name) do { if (!(cond)) { fails++; printf("FAIL %s\n", name); } else printf("ok %s\n", name); } while (0)

// 记录器
static DmSemState g_st; static int g_cancelled, g_rawN, g_skillsCancelled, g_tapN;
static int g_lastIds[16]; static float g_lastXs[16], g_lastYs[16];
static void rec_changed(void *ctx, const DmSemState *st, int cancelled,
                        const int *ids, const float *xs, const float *ys, int n, long long ms) {
    (void)ctx; (void)ms;
    g_st = *st; g_cancelled = cancelled; g_rawN = n;
    for (int i = 0; i < n; i++) { g_lastIds[i] = ids[i]; g_lastXs[i] = xs[i]; g_lastYs[i] = ys[i]; }
}
static void rec_skills(void *ctx, long long owner, const DmAimEvent *ev, int n, int w, int h, int cancelled) {
    (void)ctx; (void)owner; (void)ev; (void)n; (void)w; (void)h; g_skillsCancelled = cancelled;
}
static void rec_tap(void *ctx, long long owner, int id, float x, float y,
                    long long downMs, long long upMs, const DmSemState *snap) {
    (void)ctx; (void)owner; (void)snap; (void)downMs; (void)upMs;
    g_tapN++; g_lastIds[0] = id; g_lastXs[0] = x; g_lastYs[0] = y;
}
static void rec_pickup(void *ctx, long long token, int phase) { (void)ctx; (void)token; (void)phase; }

static const DmSemRouteListener LN = { 0, rec_changed, rec_skills, rec_tap, rec_pickup };

// 布局：0=摇杆(100,600 hw100) 1=攻击键 A(slot2, 400,600 hw60) 2=药水(button128, 650,600 hw48)
static DmSemControl g_ctrls[3];
static void setup_layout(DmSemRoute *r) {
    memset(g_ctrls, 0, sizeof g_ctrls);
    g_ctrls[0] = (DmSemControl){ 0, 0ull, -1, 100, 600, 100, 100, 100, 1, 0 };
    g_ctrls[1] = (DmSemControl){ 2, 1ull, 2, 400, 600, 60, 60, 60, 1, 0 };
    g_ctrls[2] = (DmSemControl){ 2, 128ull, -1, 650, 600, 48, 48, 48, 1, 0 };
    dmroute_bind_controls(r, g_ctrls, 3);
}

int main(void) {
    DmSemRoute r;
    dmroute_init(&r);
    r.ln = &LN;
    setup_layout(&r);

    // 1 挂代（gen=2 → owner=5，bit0=1 world）
    CHECK(dmroute_sync_owner(&r, 2, 800, 800) == 1, "first sync owner");
    CHECK(dmroute_sync_owner(&r, 2, 800, 800) == 0, "same gen = no-op");

    // 2 raw 触点 → changed_at 带归一坐标
    dmroute_down(&r, 11, -1, 400, 300, 1000);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_rawN == 1 && g_lastIds[0] == 11 && fabs(g_lastXs[0] - 0.5) < 1e-5 && fabs(g_lastYs[0] - 0.375) < 1e-5,
          "raw touch normalized to view extent");
    CHECK(g_st.buttons == 0, "raw touch no buttons");

    // 3 raw 抬起 → up（UiPointer 上游收 cnt=0）
    dmroute_up(&r, 11, 1100);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_rawN == 0, "raw released");

    // 4 技能键认领（slot2=攻击）→ 走 aim 通道（安卓技能键不进 buttons），held 计数
    dmroute_down(&r, 12, 1, 400, 600, 1200);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_rawN == 0 && g_st.buttons == 0, "attack claimed via aim channel (no semantic buttons)");
    CHECK(g_ctrls[1].held == 1, "held incremented");
    // 5 移动超 slop：技能槽 → aim dragged；不产生 raw
    dmroute_move(&r, 12, 430, 600, 1250);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_rawN == 0, "skill move not raw");
    // 6 抬起 → 键释放
    dmroute_up(&r, 12, 1300);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_st.buttons == 0 && g_ctrls[1].held == 0, "release on up");

    // 7 摇杆认领 → 落指跟随（center=落点）+ 死区内不动；轻点 <350ms 且无其他 raw → tap
    dmroute_down(&r, 13, 0, 150, 620, 2000);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(r.input.sticks[0].owner == 13 && r.input.sticks[0].cx == 150, "stick base follows touch");
    dmroute_up(&r, 13, 2100);   // 100ms < 350ms
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_tapN == 1 && g_lastIds[0] == 13 && fabs(g_lastXs[0] - 150.0 / 800.0) < 1e-5, "stick tap passthrough");
    CHECK(r.input.sticks[0].owner == 0, "stick released after tap");

    // 8 摇杆按住拖动 > slop → 摇杆动（非 raw、非 tap）
    dmroute_down(&r, 14, 0, 150, 620, 3000);
    dmroute_move(&r, 14, 200, 620, 3050);   // 50 > slop 8
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_rawN == 0 && g_st.lx > 0, "drag drives left stick");
    dmroute_up(&r, 14, 3200);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_tapN == 1, "moved stick = no tap");

    // 9 摇杆轻点但有其他 raw 触点 → 不发 tap（安卓 raw 检查）
    dmroute_down(&r, 20, -1, 500, 100, 4000);   // raw 占位
    dmroute_down(&r, 21, 0, 150, 620, 4000);
    dmroute_up(&r, 21, 4100);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_tapN == 1, "no tap while other raw present");
    dmroute_up(&r, 20, 4200);
    dmroute_publish(&r, 0, 800, 800);

    // 10 换代 → 全释放（按住的药水键松开）+ skills cancelled
    dmroute_down(&r, 22, 2, 650, 600, 5000);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_st.buttons == 128ull, "potion held before gen change");
    CHECK(dmroute_sync_owner(&r, 4, 800, 800) == 1, "generation change");
    CHECK(g_skillsCancelled == 1, "gen change cancels skills (release publish)");
    CHECK(g_ctrls[2].held == 0, "held reset");
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_st.buttons == 0, "gen change releases all");

    // 11 cancel：全部清 + cancelSkills
    dmroute_down(&r, 23, 2, 650, 600, 6000);
    dmroute_down(&r, 24, -1, 500, 100, 6000);
    dmroute_cancel(&r, 6100);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_st.buttons == 0 && g_rawN == 0 && g_ctrls[1].held == 0, "cancel clears everything");
    CHECK(g_skillsCancelled == 1, "cancel flags skills");

    // 12 长按排程：next delay 与 long_press 触发
    dmroute_down(&r, 25, 1, 400, 600, 10000);
    long long d = dmroute_next_long_press_delay(&r, 10300);
    CHECK(d == 200, "delay = down+500-now");
    CHECK(dmroute_long_press(&r, 10550) == 1, "long press fires after 500ms");
    CHECK(dmroute_long_press(&r, 10560) == 0, "no double fire (held)");
    dmroute_up(&r, 25, 10600);
    dmroute_publish(&r, 0, 800, 800);

    // 13 pickup token=0 → 拾取钮禁用（enabled=0），hit 由视图侧负责；此处验 set_pickup 不崩
    dmroute_set_pickup(&r, 0);
    dmroute_down(&r, 26, 0, 150, 620, 7000);
    dmroute_up(&r, 26, 7100);
    dmroute_publish(&r, 0, 800, 800);
    CHECK(g_tapN == 2, "tap works after all");

    printf(fails ? "SEMANTIC_ROUTE FAIL %d\n" : "SEMANTIC_ROUTE OK\n", fails);
    return fails != 0;
}
