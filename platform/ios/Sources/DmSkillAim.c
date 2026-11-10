// 安卓 SemanticSkillAim 忠实 C 移植（2026-11-10 触控重构轮）。逐条对表 jadx SemanticSkillAim.java。
#include "DmSkillAim.h"
#include <math.h>
#include <string.h>

static int finite2(float x, float y) { return isfinite(x) && isfinite(y); }

static DmAimGesture *find(DmSkillAim *a, int pointer) {
    for (int i = 0; i < a->gN; i++) if (a->pid[i] == pointer) return &a->g[i];
    return 0;
}
static void push(DmSkillAim *a, const DmAimGesture *g, int phase, int pointer) {
    if (a->evN >= DMAIM_EV_N) return;
    DmAimEvent *e = &a->ev[a->evN++];
    e->phase = phase; e->pointer = pointer; e->slot = g->slot;
    e->ox = g->ox; e->oy = g->oy; e->x = g->x; e->y = g->y;
    e->radius = g->radius; e->slop = g->slop; e->dragged = g->dragged;
}
static void gest_remove(DmSkillAim *a, int i) {
    a->g[i] = a->g[a->gN - 1]; a->pid[i] = a->pid[a->gN - 1]; a->gN--;
}

int dmaim_begin(DmSkillAim *a, int pointer, int slot, float x, float y, float radius, float slop) {
    DmAimGesture *old = find(a, pointer);
    if (old) {                       // 安卓 begin：同指已有手势先 cancel
        int i = (int)(old - a->g);
        push(a, old, 3, pointer);
        gest_remove(a, i);
    }
    if (slot < 0 || slot >= 6 || !finite2(x, y) || !isfinite(radius) || radius <= 0.0f ||
        !isfinite(slop) || slop < 0.0f) return 0;
    for (int i = 0; i < a->gN; i++) if (a->g[i].slot == slot) return 0;   // 一槽一手势
    if (a->gN >= DMAIM_GEST_N) return 0;
    DmAimGesture *g = &a->g[a->gN];
    memset(g, 0, sizeof *g);
    g->slot = slot; g->ox = g->x = x; g->oy = g->y = y;
    g->radius = radius; g->slop = slop;
    a->pid[a->gN++] = pointer;
    push(a, g, 0, pointer);
    return 1;
}

int dmaim_move(DmSkillAim *a, int pointer, float x, float y) {
    DmAimGesture *g = find(a, pointer);
    if (!g) return 0;
    if (!finite2(x, y)) { dmaim_cancel_one(a, pointer); return 1; }
    if (g->x == x && g->y == y) return 0;
    g->x = x; g->y = y;
    if (hypot((double)x - g->ox, (double)y - g->oy) > (double)g->slop) g->dragged = 1;
    push(a, g, 1, pointer);
    return 1;
}

int dmaim_can_hold(const DmSkillAim *a, int pointer) {
    for (int i = 0; i < a->gN; i++)
        if (a->pid[i] == pointer) return !a->g[i].dragged && !a->g[i].held;
    return 0;
}

int dmaim_hold(DmSkillAim *a, int pointer) {
    DmAimGesture *g = find(a, pointer);
    if (!g || g->dragged || g->held) return 0;
    g->held = 1;
    push(a, g, 4, pointer);
    return 1;
}

int dmaim_end(DmSkillAim *a, int pointer) {
    DmAimGesture *g = find(a, pointer);
    if (!g) return 0;
    push(a, g, 2, pointer);
    gest_remove(a, (int)(g - a->g));
    return 1;
}

void dmaim_cancel_one(DmSkillAim *a, int pointer) {
    DmAimGesture *g = find(a, pointer);
    if (g) {
        push(a, g, 3, pointer);
        gest_remove(a, (int)(g - a->g));
    }
}

void dmaim_cancel_all(DmSkillAim *a) {
    a->gN = 0;
    a->evN = 0;
}

int dmaim_drain(DmSkillAim *a, DmAimEvent *out, int cap) {
    int n = a->evN < cap ? a->evN : cap;
    memcpy(out, a->ev, (size_t)n * sizeof *out);
    a->evN = 0;
    return n;
}
