// UI 指针触点状态机（安卓 UiPointer.java 忠实 C 移植，kb/07 §10；2026-11-10 菜单触控轮）。
// 主指跟踪/双指对/waitForRelease 防误触语义逐条对齐；纯 C 可单测（tests/test_ui_pointer.c）。
// | Touch-point state machine — faithful C port of the Android UiPointer: primary tracking,
// | two-finger pairing, waitForRelease guard. Pure C, unit-testable.
#ifndef DM_UIPOINTER_H
#define DM_UIPOINTER_H

typedef struct {
    int down, paired, wait_release;
    int primary, secondary;
    float x, y, bx, by;
} DmUip;

typedef struct {
    int phase, paired;      // phase: 0=down 1=move 2=up 3=cancel；paired=双指对事件
    float x, y, bx, by;
} DmUipEvent;

void dm_uip_init(DmUip *p);
// 喂当前活跃触点集（未命中壳控件的 raw 集）；至多产出一个事件写入 *ev（安卓每次 publish 至多 emit 一次）。
// 返回 1=有事件。cancelled 时发 phase 3。
int dm_uip_publish(DmUip *p, const int *ids, const float *xs, const float *ys, int cnt,
                   int cancelled, long long ms, long long *out_ms, DmUipEvent *ev);
void dm_uip_cancel(DmUip *p, long long ms, long long *out_ms, DmUipEvent *ev);

#endif
