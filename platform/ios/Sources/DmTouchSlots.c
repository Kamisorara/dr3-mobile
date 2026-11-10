// 安卓 TouchSlots.java 逐行 C 移植（2026-11-10 完全照搬轮）。
// | Faithful C port of Android TouchSlots.
#include "DmTouchSlots.h"

void dmts_init(DmTouchSlots *s) { dmts_clear(s); }

void dmts_clear(DmTouchSlots *s) {
    for (int i = 0; i < DMTS_N; i++) s->ids[i] = -1;
}

void dmts_retain(DmTouchSlots *s, const int *active, int n) {
    for (int slot = 0; slot < DMTS_N; slot++) {
        if (s->ids[slot] < 0) continue;
        int alive = 0;
        for (int i = 0; i < n; i++)
            if (active[i] == s->ids[slot]) { alive = 1; break; }
        if (!alive) s->ids[slot] = -1;
    }
}

int dmts_slot(DmTouchSlots *s, int id) {
    if (id < 0) return -1;
    for (int slot = 0; slot < DMTS_N; slot++)
        if (s->ids[slot] == id) return slot;
    for (int slot = 0; slot < DMTS_N; slot++)
        if (s->ids[slot] < 0) { s->ids[slot] = id; return slot; }
    return -1;
}
