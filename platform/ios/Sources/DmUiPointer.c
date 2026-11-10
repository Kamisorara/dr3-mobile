// 安卓 UiPointer.java 的 C 移植（publishPair/cancel 逐条对齐；kb/07 §10）。
// 语义对照：主指按下 emit(0)；主指动 emit(1)；主指失联/第二指失联 → up + waitForRelease
// （等全部抬起才收新主指，防误触）；cancel 恒发相位 3。
#include "DmUiPointer.h"
#include <string.h>

static int index_of(const int *ids, int cnt, int id) {
    for (int i = 0; i < cnt; i++) if (ids[i] == id) return i;
    return -1;
}

void dm_uip_init(DmUip *p) { memset(p, 0, sizeof *p); }

static int emit_pair(DmUip *p, int phase, long long ms, long long *out_ms, DmUipEvent *ev) {
    ev->phase = phase; ev->paired = 1;
    ev->x = p->x; ev->y = p->y; ev->bx = p->bx; ev->by = p->by;
    if (out_ms) *out_ms = ms;
    return 1;
}

static int emit_single(DmUip *p, int phase, long long ms, long long *out_ms, DmUipEvent *ev) {
    ev->phase = phase; ev->paired = 0;
    ev->x = p->x; ev->y = p->y; ev->bx = 0; ev->by = 0;
    if (out_ms) *out_ms = ms;
    return 1;
}

int dm_uip_publish(DmUip *p, const int *ids, const float *xs, const float *ys, int cnt,
                   int cancelled, long long ms, long long *out_ms, DmUipEvent *ev) {
    if (cancelled) { dm_uip_cancel(p, ms, out_ms, ev); return 1; }
    if (cnt == 0) {
        int r = 0;
        if (p->paired) r = emit_pair(p, 2, ms, out_ms, ev);
        else if (p->down) r = emit_single(p, 2, ms, out_ms, ev);
        p->paired = 0; p->down = 0; p->wait_release = 0;   // 安卓：三旗无条件清（排空即恢复接收）
        return r;
    }
    if (p->wait_release) return 0;
    int r = 0;                                // 本调用发过任何事件即 1（安卓回调可能连发两条，单槽只留最后一条）
    if (!p->down) {
        p->primary = ids[0]; p->x = xs[0]; p->y = ys[0];
        p->down = 1;
        emit_single(p, 0, ms, out_ms, ev); r = 1;   // 安卓：down 后继续走 move/pair 扫描
    }
    int a = index_of(ids, cnt, p->primary);
    if (a < 0) {                              // 主指失联
        emit_single(p, 2, ms, out_ms, ev);
        p->paired = 0; p->down = 0; p->wait_release = 1;
        return 1;
    }
    if (p->paired) {
        int b = index_of(ids, cnt, p->secondary);
        if (b < 0) {                          // 第二指失联
            emit_pair(p, 2, ms, out_ms, ev);
            p->paired = 0; p->down = 0; p->wait_release = 1;
            return 1;
        }
        if (p->x != xs[a] || p->y != ys[a] || p->bx != xs[b] || p->by != ys[b]) {
            p->x = xs[a]; p->y = ys[a]; p->bx = xs[b]; p->by = ys[b];
            return emit_pair(p, 1, ms, out_ms, ev);
        }
        return r;
    }
    if (p->x != xs[a] || p->y != ys[a]) {
        p->x = xs[a]; p->y = ys[a];
        emit_single(p, 1, ms, out_ms, ev); r = 1;    // 安卓：move 后不 return，继续扫第二指
    }
    for (int b = 0; b < cnt; b++) {
        if (ids[b] != p->primary) {
            p->secondary = ids[b]; p->bx = xs[b]; p->by = ys[b];
            p->paired = 1;
            return emit_pair(p, 0, ms, out_ms, ev);
        }
    }
    return r;
}

void dm_uip_cancel(DmUip *p, long long ms, long long *out_ms, DmUipEvent *ev) {
    int r = p->paired ? emit_pair(p, 3, ms, out_ms, ev) : emit_single(p, 3, ms, out_ms, ev);
    (void)r;
    p->paired = 0; p->down = 0; p->wait_release = 0;
}
