// 安卓 SemanticInput 忠实 C 移植（2026-11-10 触控重构轮）。逐条对表 jadx SemanticInput.java。
#include "DmSemanticInput.h"
#include <math.h>
#include <string.h>

static int axis(double v) {
    long r = lround(v);
    if (r > 32767) r = 32767;
    if (r < -32767) r = -32767;
    return (int)r;
}

void dmsi_init(DmSemInput *s) {
    memset(s, 0, sizeof *s);
    s->deadZone = 0.12f;
}

void dmsi_press(DmSemInput *s, int pid, unsigned long long buttons) {
    for (int i = 0; i < s->heldN; i++) {
        if (s->held[i].pid == pid) {
            if (buttons == 0) { s->held[i] = s->held[--s->heldN]; }
            else s->held[i].buttons = (long long)buttons;
            return;
        }
    }
    if (buttons == 0 || s->heldN >= DMSI_HELD_N) return;
    s->held[s->heldN].pid = pid;
    s->held[s->heldN].buttons = (long long)buttons;
    s->heldN++;
}

static void stick_clear(DmSemStick *st) {
    st->owner = 0; st->x = 0; st->y = 0;
}

void dmsi_release(DmSemInput *s, int pid) {
    dmsi_press(s, pid, 0);
    for (int i = 0; i < 2; i++)
        if (s->sticks[i].owner == pid) stick_clear(&s->sticks[i]);
}

int dmsi_begin_stick(DmSemInput *s, int pid, int stick, float cx, float cy, float radius) {
    if (stick < 0 || stick >= 2 || !isfinite(cx) || !isfinite(cy) || !isfinite(radius) || radius <= 0.0f) return 0;
    DmSemStick *t = &s->sticks[stick];
    if (t->owner) return t->owner == pid;
    t->owner = pid; t->cx = cx; t->cy = cy; t->radius = radius;
    t->x = 0; t->y = 0;
    return 1;
}

void dmsi_move(DmSemInput *s, int pid, float x, float y) {
    for (int i = 0; i < 2; i++) {
        DmSemStick *st = &s->sticks[i];
        if (!st->owner || st->owner != pid) continue;
        if (!isfinite(x) || !isfinite(y)) { st->x = 0; st->y = 0; continue; }
        double dx = (double)x - st->cx;
        double dy = st->cy - (double)y;   // 安卓：centerY - y（上=正）
        double dist = hypot(dx, dy);
        double mag = dist / (double)st->radius;
        if (mag > 1.0) mag = 1.0;
        if (mag <= (double)s->deadZone) { st->x = 0; st->y = 0; continue; }
        double out = ((mag - (double)s->deadZone) / (double)(1.0f - s->deadZone)) * 32767.0;
        st->x = axis(dx / dist * out);
        st->y = axis(dy / dist * out);
    }
}

void dmsi_cancel(DmSemInput *s) {
    s->heldN = 0;
    s->evadeN = 0;
    s->cancelEvades = 1;
    for (int i = 0; i < 2; i++) stick_clear(&s->sticks[i]);
}

void dmsi_evade(DmSemInput *s) {
    double len = hypot((double)s->sticks[0].x, (double)s->sticks[0].y);
    int vx = len > 0.0 ? axis((double)s->sticks[0].x / len * 32767.0) : 0;
    int vy = len > 0.0 ? axis((double)s->sticks[0].y / len * 32767.0) : 0;
    if (s->evadeN + 2 > DMSI_EVADE_N) return;
    s->evades[s->evadeN++] = vx;
    s->evades[s->evadeN++] = vy;
}

void dmsi_discard_evades(DmSemInput *s) {
    s->evadeN = 0;
    s->cancelEvades = 1;
}

DmSemState dmsi_snapshot(const DmSemInput *s) {
    DmSemState st;
    memset(&st, 0, sizeof st);
    for (int i = 0; i < s->heldN; i++) st.buttons |= s->held[i].buttons;
    st.lx = s->sticks[0].x; st.ly = s->sticks[0].y;
    st.rx = s->sticks[1].x; st.ry = s->sticks[1].y;
    return st;
}

DmSemState dmsi_publication(DmSemInput *s) {
    DmSemState st = dmsi_snapshot(s);
    st.evadeN = 0;
    for (int i = 0; i < s->evadeN && st.evadeN < 8; i++) st.evade[st.evadeN++] = s->evades[i];
    s->evadeN = 0;
    st.cancelEvades = s->cancelEvades;
    s->cancelEvades = 0;
    return st;
}
