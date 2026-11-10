// DmSemanticLayout 单测：安卓 SemanticControlsView$Layout 语义逐项对表（kb/07 §12）。
// | Unit tests for the Android Layout engine port: anchors, arc table, hit priority, empty world.
#include <stdio.h>
#include <math.h>
#include "DmSemanticLayout.h"

static int fails;
#define CHECK(cond, name) do { if (!(cond)) { fails++; printf("FAIL %s\n", name); } else printf("ok %s\n", name); } while (0)

// 找控件：按 button+slot
static const DmSemControl *find(const DmSemLayout *L, unsigned long long btn, int slot) {
    for (int i = 0; i < L->n; i++)
        if (L->c[i].button == btn && (slot < 0 || L->c[i].slot == slot)) return &L->c[i];
    return 0;
}

int main(void) {
    // === 1280×720 视图、无安全区、density=2 ===
    DmSemLayout L;
    dm_semlayout_build(&L, 1280, 720, 2.0f, 0, 0, 0, 0, 1, 0.0f, 1);
    float availW = 1280, availH = 720;
    float scale = availW / 1851.0f < availH / 849.0f ? availW / 1851.0f : availH / 849.0f;   // 720/849≈0.848
    CHECK(fabsf(L.scale - scale) < 1e-4, "scale = min(w/1851,h/849)");
    // 右组锚右下：groupLeft = 1280 - 1851*scale, groupTop = 720 - 849*scale
    float gl = 1280.0f - 1851.0f * scale, gt = 720.0f - 849.0f * scale;
    const DmSemControl *atk = find(&L, 1ull, 2);
    CHECK(atk && fabsf(atk->x - (gl + 1650.0f * scale)) < 0.5f && fabsf(atk->y - (gt + 735.0f * scale)) < 0.5f,
          "attack A at group(1650,735) r94");
    CHECK(atk && fabsf(atk->halfW - 94.0f * scale) < 0.1f, "attack halfW = 94*scale");
    // 弧键 0（slot5）：角 180° → x = 1650-220, y = 777
    const DmSemControl *a0 = find(&L, 512ull, 5);
    CHECK(a0 && fabsf(a0->x - (gl + 1430.0f * scale)) < 0.5f && fabsf(a0->y - (gt + 777.0f * scale)) < 0.5f,
          "arc slot5 at 180deg orbit 220");
    // 弧键 2（slot3）：角 245° → (1650+220cos245, 777+220sin245)
    const DmSemControl *a2 = find(&L, 4ull, 3);
    float e2x = 1650.0f + 220.0f * (float)cos(245.0 * 3.14159265358979323846 / 180.0);
    float e2y = 777.0f + 220.0f * (float)sin(245.0 * 3.14159265358979323846 / 180.0);
    CHECK(a2 && fabsf(a2->x - (gl + e2x * scale)) < 0.5f && fabsf(a2->y - (gt + e2y * scale)) < 0.5f,
          "arc slot3 at 245deg");
    // 摇杆锚左 + groupTop：位置 = (0+190*scale, groupTop+620*scale)
    const DmSemControl *joy = find(&L, 0ull, -1);
    CHECK(joy && fabsf(joy->x - 190.0f * scale) < 0.5f && fabsf(joy->y - (gt + 620.0f * scale)) < 0.5f,
          "stick at (left+190s, groupTop+620s)");
    CHECK(joy && joy->kind == 0, "stick kind 0");
    // 摇杆认领区 = 左 40% × 下半
    CHECK(fabsf(L.stickR - 0.4f * 1280.0f) < 0.1f && fabsf(L.stickT - 360.0f) < 0.1f && fabsf(L.stickB - 720.0f) < 0.1f,
          "stick zone left40% x lower half");
    // 控件数：包+单+摇杆+城+药+闪+攻+弧5+拾取 = 13
    CHECK(L.n == 13, "13 controls with pickup");
    // 顶排：包/单都在 (x, top+64*scale)、r=42*scale
    const DmSemControl *bag = find(&L, 1024ull, -1), *menu = find(&L, 2048ull, -1);
    CHECK(bag && menu && fabsf(bag->y - 64.0f * scale) < 0.5f && fabsf(menu->y - 64.0f * scale) < 0.5f,
          "bag/menu at top+64*scale");
    CHECK(bag && menu && menu->x - bag->x > 0, "bag left of menu");
    // 拾取钮存在（includePickup）
    CHECK(find(&L, 0ull, -1) && ((find(&L, 16384ull, -1) && find(&L, 128ull, -1))), "portal/potion present");

    // === hit 优先级：拾取 > 弧 > 攻（倒序扫）===
    // 拾取中心 (gl+1685s, gt+425s)
    float px = gl + 1685.0f * scale, py = gt + 425.0f * scale;
    int hi = dm_semlayout_hit(&L, px, py);
    CHECK(hi >= 0 && L.c[hi].kind == 4, "pickup center hits pickup");
    // 攻击中心：最近的非拾取命中是攻击
    hi = dm_semlayout_hit(&L, atk->x, atk->y);
    CHECK(hi >= 0 && L.c[hi].button == 1ull, "attack center hits attack");
    // 摇杆区空处 → 摇杆兜底
    hi = dm_semlayout_hit(&L, 100.0f * scale, 700.0f);
    CHECK(hi >= 0 && L.c[hi].kind == 0, "stick region fallback");
    // 右上角空白（顶排之上、控件之外）→ -1
    CHECK(dm_semlayout_hit(&L, 200.0f, 20.0f) < 0, "empty corner = -1");
    // 拾取禁用后 hit 跳过（安卓 enabled=false）
    DmSemLayout L2 = L;
    for (int i = 0; i < L2.n; i++) if (L2.c[i].kind == 4) L2.c[i].enabled = 0;
    CHECK(dm_semlayout_hit(&L2, px, py) < 0 || L2.c[dm_semlayout_hit(&L2, px, py)].kind != 4,
          "disabled pickup skipped");

    // === worldControls=0 → 空布局（安卓 controls=new Control[0]），摇杆区仍计算 ===
    DmSemLayout L3;
    dm_semlayout_build(&L3, 1280, 720, 2.0f, 0, 0, 0, 0, 0, 0.0f, 1);
    CHECK(L3.n == 0, "world=0 empty layout");
    CHECK(fabsf(L3.stickB - 720.0f) < 0.1f, "stick zone kept when empty");
    CHECK(dm_semlayout_hit(&L3, 640, 600) < 0, "no hit when empty");

    // === rightMargin：右组 x -= margin*unit，顶排/摇杆不动 ===
    DmSemLayout L4;
    dm_semlayout_build(&L4, 1280, 720, 2.0f, 0, 0, 0, 0, 1, 30.0f, 0);
    float unit = 2.0f < (availW / 720.0f < availH / 400.0f ? availW / 720.0f : availH / 400.0f) ? 2.0f
                 : (availW / 720.0f < availH / 400.0f ? availW / 720.0f : availH / 400.0f);
    const DmSemControl *atk4 = find(&L4, 1ull, 2);
    CHECK(atk4 && fabsf(atk4->x - (atk->x - 30.0f * unit)) < 0.5f, "right group shifted by margin*unit");
    const DmSemControl *joy4 = find(&L4, 0ull, -1);
    CHECK(joy4 && fabsf(joy4->x - joy->x) < 0.1f, "stick not shifted");

    // === roleBottomNormalized：非顶排 max(y+halfH)/viewH ===
    float rb = dm_semlayout_role_bottom(&L, 720.0f);
    float exp = -1.0f;
    for (int i = 0; i < L.n; i++)
        if (L.c[i].button != 1024ull && L.c[i].button != 2048ull) {
            float b = L.c[i].y + L.c[i].halfH;
            if (b > exp) exp = b;
        }
    CHECK(fabsf(rb - exp / 720.0f) < 1e-4, "role bottom normalized");
    CHECK(dm_semlayout_role_bottom(&L3, 720.0f) == -1.0f, "role bottom -1 when empty");

    printf(fails ? "SEMANTIC_LAYOUT FAIL %d\n" : "SEMANTIC_LAYOUT OK\n", fails);
    return fails != 0;
}
