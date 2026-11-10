// 安卓 SemanticControlsView$Route 忠实 C 移植（2026-11-10 触控重构轮）。逐条对表 jadx Route。
// 设计 = 安卓同款：Route 直接持有/改写 DmSemControl.held（对象共享）；视图每次 rebuild 后
// dmroute_bind_controls 重绑（绑定前必须已 releaseSemantic/cancel——安卓同序，owner 不跨布局存活）。
#include "DmSemanticRoute.h"
#include <math.h>
#include <string.h>

#define STICK_TAP_MS 350
#define NAN_F (0.0f / 0.0f)

void dmroute_init(DmSemRoute *r) {
    memset(r, 0, sizeof *r);
    dmsi_init(&r->input);
    r->ownerGeneration = -1;
    r->touchSlop = 8;
    r->longPressMs = 500;
}

// 视图在 rebuild 后绑定当前布局控件表（安卓：route 直接引用 layout.controls 的同一批 Control）
void dmroute_bind_controls(DmSemRoute *r, DmSemControl *c, int n) { r->ctrl = c; r->ctrlN = n; }
void dmroute_set_listener(DmSemRoute *r, const DmSemRouteListener *ln) { r->ln = ln; }

static DmSemControl *ctrl_at(DmSemRoute *r, int idx) {
    if (!r->ctrl || idx < 0 || idx >= r->ctrlN) return 0;
    return &r->ctrl[idx];
}

static DmRouteOwner *own_find(DmSemRoute *r, int id) {
    for (int i = 0; i < r->ownN; i++) if (r->own[i].pid == id) return &r->own[i];
    return 0;
}
static void own_remove(DmSemRoute *r, int i) {
    r->own[i] = r->own[r->ownN - 1]; r->ownN--;
}

static void finish_pickup(DmSemRoute *r, DmRouteOwner *o, int phase) {
    long long token = o->pickupToken;
    o->pickupToken = 0;
    if (token == 0 || !r->ln || !r->ln->pickup) return;
    r->ln->pickup(r->ln->ctx, token, phase);
}

static void cancel_pickup(DmSemRoute *r) {
    for (int i = 0; i < r->ownN; i++) {
        DmRouteOwner *o = &r->own[i];
        if (o->pickupToken) {
            finish_pickup(r, o, 3);
            DmSemControl *c = ctrl_at(r, o->ctrl);
            if (o->active) { o->active = 0; if (c) c->held--; }
        }
    }
}

void dmroute_set_pickup(DmSemRoute *r, long long token) {
    if (token == r->pickupToken) return;
    cancel_pickup(r);
    r->pickupToken = token;
    for (int i = 0; i < r->ctrlN; i++)                       // 安卓 setPickupState：kind4 enabled 跟 token
        if (r->ctrl[i].kind == 4) r->ctrl[i].enabled = token != 0;
}

static int retire(DmSemRoute *r, int id, int allowTap) {
    DmRouteOwner *o = own_find(r, id);
    if (!o) return 0;
    DmRouteOwner owner = *o;
    DmSemControl *c = ctrl_at(r, owner.ctrl);
    own_remove(r, (int)(o - r->own));
    if (c && owner.active) {
        if (c->kind == 4) finish_pickup(r, &owner, allowTap ? 2 : 3);
        if (c->kind != 0 || owner.moved) c->held--;
        if (c->slot >= 0) {
            if (allowTap) dmaim_end(&r->aim, id);
            else dmaim_cancel_one(&r->aim, id);
        }
    }
    dmsi_release(&r->input, id);
    if (allowTap && owner.active && c && c->kind == 0 && !owner.moved &&
        r->eventMs >= owner.downMs && r->eventMs - owner.downMs < STICK_TAP_MS && r->ownerGeneration >= 0) {
        int raw = 0;
        for (int i = 0; i < r->ownN; i++) if (r->own[i].ctrl < 0) raw = 1;
        if (!raw) {   // 安卓：仅当没有其他 raw 触点才记轻点
            r->tapValid = 1; r->tapId = id;
            r->tapX = owner.downX; r->tapY = owner.downY;
            r->tapDownMs = owner.downMs;
            r->tapOwner = (r->ownerGeneration << 1) | 1;
        }
    }
    return 1;
}

void dmroute_down(DmSemRoute *r, int id, int ctrl, float x, float y, long long ms) {
    r->eventMs = ms;
    if (own_find(r, id)) dmaim_cancel_one(&r->aim, id);
    retire(r, id, 0);
    DmSemControl *c = ctrl_at(r, ctrl);
    int active = 1;
    if (c) {
        if (c->slot >= 0) active = dmaim_begin(&r->aim, id, c->slot, x, y, c->halfW, (float)r->touchSlop);
        else if (c->kind == 4) {
            active = r->pickupToken != 0;
            for (int i = 0; i < r->ownN; i++) if (r->own[i].pickupToken) active = 0;
        } else if (c->kind == 2) dmsi_press(&r->input, id, c->button);
        else if (c->kind == 3) dmsi_evade(&r->input);
        else if (c->kind == 0) {
            active = dmsi_begin_stick(&r->input, id, 0, x, y, c->halfW);
            if (active) dmsi_move(&r->input, id, x, y);
        }
        if (active && c->kind != 0) c->held++;
    }
    if (r->ownN >= DMROUTE_OWN_N) return;
    DmRouteOwner *o = &r->own[r->ownN++];
    memset(o, 0, sizeof *o);
    o->pid = id; o->ctrl = ctrl; o->active = active;
    o->x = o->downX = x; o->y = o->downY = y; o->downMs = ms;
    if (active && c && c->kind == 4) {
        o->pickupToken = r->pickupToken;
        if (r->ln && r->ln->pickup) r->ln->pickup(r->ln->ctx, o->pickupToken, 0);
    }
}

void dmroute_move(DmSemRoute *r, int id, float x, float y, long long ms) {
    r->eventMs = ms;
    DmRouteOwner *o = own_find(r, id);
    if (!o || (o->x == x && o->y == y)) return;
    DmSemControl *c = ctrl_at(r, o->ctrl);
    if (!c) { o->x = x; o->y = y; return; }                    // raw 触点：只更新坐标
    if (o->active && c->slot >= 0) {
        o->x = x; o->y = y;
        dmaim_move(&r->aim, id, x, y);
        return;
    }
    if (c->kind == 4) {
        o->x = x; o->y = y;
        if (o->active) {
            float dx = x - c->x, dy = y - c->y;
            if (dx * dx + dy * dy > c->hitRadius * c->hitRadius) {   // 拖出钮圆 → 取消拾取
                finish_pickup(r, o, 3);
                o->active = 0;
                c->held--;
            }
        }
        return;
    }
    if (!o->active || c->kind != 0) return;
    o->x = x; o->y = y;
    int dragged = !(isfinite(x) && isfinite(y) &&
                    hypot((double)x - o->downX, (double)y - o->downY) <= (double)r->touchSlop);
    if (!o->moved) {
        if (!dragged) return;
        o->moved = 1;
        c->held++;
    }
    dmsi_move(&r->input, id, x, y);
}

void dmroute_up(DmSemRoute *r, int id, long long ms) {
    r->eventMs = ms;
    DmRouteOwner *o = own_find(r, id);
    DmSemControl *c = o ? ctrl_at(r, o->ctrl) : 0;
    if (o && o->active && c && c->slot >= 0 &&
        r->eventMs >= o->downMs && r->eventMs - o->downMs >= r->longPressMs)
        dmaim_hold(&r->aim, id);
    retire(r, id, 1);
}

void dmroute_cancel(DmSemRoute *r, long long ms) {
    r->eventMs = ms;
    cancel_pickup(r);
    r->tapValid = 0;
    for (int i = 0; i < r->ownN; i++) {
        DmRouteOwner *o = &r->own[i];
        DmSemControl *c = ctrl_at(r, o->ctrl);
        if (c && o->active && (c->kind != 0 || o->moved)) c->held--;
    }
    r->ownN = 0;
    dmsi_cancel(&r->input);
    dmaim_cancel_all(&r->aim);
    r->cancelSkills = 1;
}

static void release_semantic(DmSemRoute *r, int w, int h) {
    cancel_pickup(r);
    r->pickupToken = 0;
    r->tapValid = 0;
    dmsi_discard_evades(&r->input);
    dmaim_cancel_all(&r->aim);
    r->cancelSkills = 1;
    for (int i = 0; i < r->ownN; i++) {
        DmRouteOwner *o = &r->own[i];
        DmSemControl *c = ctrl_at(r, o->ctrl);
        if (c && o->active) {
            if (c->kind != 0 || o->moved) c->held--;
            dmsi_release(&r->input, o->pid);
            o->active = 0;
        }
    }
    dmroute_publish(r, 0, w, h);
}

int dmroute_sync_owner(DmSemRoute *r, long long generation, int w, int h) {
    if (r->ownerGeneration == generation) return 0;
    r->ownerGeneration = generation;
    release_semantic(r, w, h);
    return 1;
}

static float normalized(float v, int extent) { return extent > 0 ? v / (float)extent : NAN_F; }

void dmroute_publish(DmSemRoute *r, int cancelled, int w, int h) {
    if (!r->ln || !r->ln->changed_at) return;
    int ids[DMROUTE_OWN_N]; float xs[DMROUTE_OWN_N], ys[DMROUTE_OWN_N]; int n = 0;
    for (int i = 0; i < r->ownN; i++) {
        if (r->own[i].ctrl < 0) {
            ids[n] = r->own[i].pid;
            xs[n] = normalized(r->own[i].x, w);
            ys[n] = normalized(r->own[i].y, h);
            n++;
        }
    }
    DmSemState st = dmsi_publication(&r->input);
    long long sourceOwner = (r->ownerGeneration << 1) | 1;
    DmAimEvent ev[DMAIM_EV_N];
    int evn = dmaim_drain(&r->aim, ev, DMAIM_EV_N);
    int skillCancelled = cancelled || r->cancelSkills;
    r->cancelSkills = 0;
    r->ln->changed_at(r->ln->ctx, &st, cancelled, ids, xs, ys, n, r->eventMs);
    if (r->ln->skills) r->ln->skills(r->ln->ctx, sourceOwner, ev, evn, w, h, skillCancelled);
    // 安卓：this.tap=null 先清后判（本拍 raw 非空/换代即弃，不结转到下一拍）
    int fire = !cancelled && r->tapValid && n == 0 && r->tapOwner == ((r->ownerGeneration << 1) | 1) && r->ln->tap;
    int tapId = r->tapId; float tapX = normalized(r->tapX, w), tapY = normalized(r->tapY, h);
    long long tapDown = r->tapDownMs, tapOwner = r->tapOwner;
    r->tapValid = 0;
    if (fire) {
        DmSemState snap = dmsi_snapshot(&r->input);
        r->ln->tap(r->ln->ctx, tapOwner, tapId, tapX, tapY, tapDown, r->eventMs, &snap);
    }
}

long long dmroute_next_long_press_delay(const DmSemRoute *r, long long now) {
    long long delay = -1;
    for (int i = 0; i < r->ownN; i++) {
        const DmRouteOwner *o = &r->own[i];
        DmSemControl *c = ctrl_at((DmSemRoute *)r, o->ctrl);
        if (o->active && c && c->slot >= 0 && dmaim_can_hold(&r->aim, o->pid)) {
            long long d = (o->downMs + r->longPressMs) - now;
            if (d < 0) d = 0;
            if (delay < 0 || d < delay) delay = d;
        }
    }
    return delay;
}

int dmroute_long_press(DmSemRoute *r, long long now) {
    int changed = 0;
    for (int i = 0; i < r->ownN; i++) {
        const DmRouteOwner *o = &r->own[i];
        DmSemControl *c = ctrl_at(r, o->ctrl);
        if (o->active && c && c->slot >= 0 && now >= o->downMs && now - o->downMs >= r->longPressMs)
            changed |= dmaim_hold(&r->aim, o->pid);
    }
    if (changed) r->eventMs = now;
    return changed;
}
