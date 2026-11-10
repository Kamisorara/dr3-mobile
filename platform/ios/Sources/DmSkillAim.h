// 安卓 SemanticSkillAim 忠实 C 移植（jadx 全文对表；2026-11-10 触控重构轮）。
// 技能瞄准手势状态机：一指一手势、一槽一手势；phase 0=down 1=move 2=up 3=cancel 4=hold；
// slop 内=轻点、超 slop=dragged、长按未拖=hold。纯 C 可单测（tests/test_skill_aim.c）。
// | Faithful C port of Android SemanticSkillAim gesture state machine. Pure C, unit-testable.
#ifndef DM_SKILL_AIM_H
#define DM_SKILL_AIM_H

#define DMAIM_GEST_N 8
#define DMAIM_EV_N 32

typedef struct {
    int phase, pointer, slot;
    float ox, oy, x, y, radius, slop;
    int dragged;
} DmAimEvent;

typedef struct {
    int slot, held, dragged;
    float ox, oy, x, y, radius, slop;
} DmAimGesture;

typedef struct {
    DmAimGesture g[DMAIM_GEST_N]; int gN;    // g[i].slot>=0 视为在用（pointer 存 pid）
    int pid[DMAIM_GEST_N];
    DmAimEvent ev[DMAIM_EV_N]; int evN;
} DmSkillAim;

int  dmaim_begin(DmSkillAim *a, int pointer, int slot, float x, float y, float radius, float slop);
int  dmaim_move(DmSkillAim *a, int pointer, float x, float y);
int  dmaim_can_hold(const DmSkillAim *a, int pointer);
int  dmaim_hold(DmSkillAim *a, int pointer);
int  dmaim_end(DmSkillAim *a, int pointer);
void dmaim_cancel_one(DmSkillAim *a, int pointer);
void dmaim_cancel_all(DmSkillAim *a);
int  dmaim_drain(DmSkillAim *a, DmAimEvent *out, int cap);   // → 事件数

#endif
